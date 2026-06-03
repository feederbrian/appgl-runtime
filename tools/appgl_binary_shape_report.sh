#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  tools/appgl_binary_shape_report.sh \
    --dylib PATH \
    --out FILE \
    [--cmake-cache PATH] \
    [--artifact-id ID] \
    [--variant TEXT] \
    [--source-commit SHA] \
    [--parent-commit SHA] \
    [--require-release-shape] \
    [--diagnostic-label TEXT]

Writes a stable Mach-O binary-shape report for libAppGL.dylib.

By default this is report-only. --require-release-shape turns the report into a
release gate. Use --diagnostic-label for explicit diagnostic/debug artifact
opt-out; diagnostic artifacts still get a full report, but release-shape failures
do not fail the command.

Thresholds are env-overridable:
  APPGL_SHAPE_MAX_SIZE_BYTES
  APPGL_SHAPE_MAX_NM_M_LINES
  APPGL_SHAPE_MAX_STUBS_BYTES
  APPGL_SHAPE_MAX_LINKEDIT_FILESIZE
EOF
}

die() {
    printf 'appgl_binary_shape_report: %s\n' "$*" >&2
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

append_failure() {
    failures+=("$1")
}

abs_path() {
    local path="$1"
    local dir
    dir="$(cd "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}

dylib=""
out=""
cmake_cache=""
artifact_id=""
variant=""
source_commit=""
parent_commit=""
require_release=0
diagnostic_label=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dylib) dylib="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --cmake-cache) cmake_cache="${2:-}"; shift 2 ;;
        --artifact-id) artifact_id="${2:-}"; shift 2 ;;
        --variant) variant="${2:-}"; shift 2 ;;
        --source-commit) source_commit="${2:-}"; shift 2 ;;
        --parent-commit) parent_commit="${2:-}"; shift 2 ;;
        --require-release-shape) require_release=1; shift ;;
        --diagnostic-label) diagnostic_label="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$dylib" ] || die "--dylib is required"
[ -n "$out" ] || die "--out is required"
[ -f "$dylib" ] || die "missing dylib: $dylib"

dylib="$(abs_path "$dylib")"
mkdir -p "$(dirname "$out")"

max_size="${APPGL_SHAPE_MAX_SIZE_BYTES:-15728640}"
max_nm_lines="${APPGL_SHAPE_MAX_NM_M_LINES:-35000}"
max_stubs="${APPGL_SHAPE_MAX_STUBS_BYTES:-20000}"
max_linkedit="${APPGL_SHAPE_MAX_LINKEDIT_FILESIZE:-5242880}"

dylib_sha="$(shasum -a 256 "$dylib" | awk '{print $1}')"
dylib_uuid="$(dwarfdump --uuid "$dylib" | awk '/UUID:/ {print $2; exit}')"
dylib_arch="$(lipo -archs "$dylib")"
dylib_size="$(stat -f '%z' "$dylib")"
file_summary="$(file "$dylib")"
install_name="$(otool -D "$dylib" | awk 'NR == 2 {print; exit}')"
nm_m_lines="$(nm -m "$dylib" | wc -l | tr -d ' ')"
size_m_text="$(size -m "$dylib")"
stubs_size="$(printf '%s\n' "$size_m_text" | awk '/Section __stubs:/ {print $3; exit}')"
[ -n "$stubs_size" ] || stubs_size="0"
stubs_hex="$(printf '0x%016x' "$stubs_size")"
linkedit_vmsize="$(otool -l "$dylib" | awk '
    /segname __LINKEDIT/ { in_segment = 1; next }
    in_segment && $1 == "vmsize" { print $2; exit }
')"
linkedit_filesize="$(otool -l "$dylib" | awk '
    /segname __LINKEDIT/ { in_segment = 1; next }
    in_segment && $1 == "filesize" { print $2; exit }
')"
[ -n "$linkedit_vmsize" ] || linkedit_vmsize="unknown"
[ -n "$linkedit_filesize" ] || linkedit_filesize="0"

cmake_build_type=""
cmake_cxx_flags_release=""
cmake_objcxx_flags_release=""
appgl_enable_asan=""
appgl_dcr_sentinel_hooks=""
appgl_vendor_third_party=""
appgl_fp64_emulation=""
appgl_log_all=""
appgl_log_draw=""
appgl_log_shader=""
appgl_log_texture=""
appgl_log_buffer=""
appgl_log_pipeline=""

if [ -n "$cmake_cache" ] && [ -f "$cmake_cache" ]; then
    cmake_cache="$(abs_path "$cmake_cache")"
    cmake_build_type="$(cache_value "$cmake_cache" CMAKE_BUILD_TYPE)"
    cmake_cxx_flags_release="$(cache_value "$cmake_cache" CMAKE_CXX_FLAGS_RELEASE)"
    cmake_objcxx_flags_release="$(cache_value "$cmake_cache" CMAKE_OBJCXX_FLAGS_RELEASE)"
    appgl_enable_asan="$(cache_value "$cmake_cache" APPGL_ENABLE_ASAN)"
    appgl_dcr_sentinel_hooks="$(cache_value "$cmake_cache" APPGL_DCR_SENTINEL_HOOKS)"
    appgl_vendor_third_party="$(cache_value "$cmake_cache" APPGL_VENDOR_THIRD_PARTY)"
    appgl_fp64_emulation="$(cache_value "$cmake_cache" APPGL_FP64_EMULATION)"
    appgl_log_all="$(cache_value "$cmake_cache" APPGL_LOG_ALL)"
    appgl_log_draw="$(cache_value "$cmake_cache" APPGL_LOG_DRAW)"
    appgl_log_shader="$(cache_value "$cmake_cache" APPGL_LOG_SHADER)"
    appgl_log_texture="$(cache_value "$cmake_cache" APPGL_LOG_TEXTURE)"
    appgl_log_buffer="$(cache_value "$cmake_cache" APPGL_LOG_BUFFER)"
    appgl_log_pipeline="$(cache_value "$cmake_cache" APPGL_LOG_PIPELINE)"
fi

failures=()
release_shape_required="no"
release_shape_status="NOT_REQUIRED"
if [ "$require_release" -eq 1 ] && [ -z "$diagnostic_label" ]; then
    release_shape_required="yes"
    release_shape_status="PASS"

    [ -n "$cmake_cache" ] && [ -f "$cmake_cache" ] \
        || append_failure "missing CMakeCache.txt for strict release gate"
    [ "$cmake_build_type" = "Release" ] \
        || append_failure "CMAKE_BUILD_TYPE must be Release (was '${cmake_build_type:-unset}')"
    [[ "$cmake_cxx_flags_release" == *"-O3"* ]] \
        || append_failure "CMAKE_CXX_FLAGS_RELEASE must include -O3"
    [[ "$cmake_cxx_flags_release" == *"-DNDEBUG"* ]] \
        || append_failure "CMAKE_CXX_FLAGS_RELEASE must include -DNDEBUG"
    [[ "$cmake_objcxx_flags_release" == *"-O3"* ]] \
        || append_failure "CMAKE_OBJCXX_FLAGS_RELEASE must include -O3"
    [[ "$cmake_objcxx_flags_release" == *"-DNDEBUG"* ]] \
        || append_failure "CMAKE_OBJCXX_FLAGS_RELEASE must include -DNDEBUG"
    [ "$appgl_enable_asan" = "OFF" ] \
        || append_failure "APPGL_ENABLE_ASAN must be OFF (was '${appgl_enable_asan:-unset}')"
    [ "$appgl_dcr_sentinel_hooks" = "OFF" ] \
        || append_failure "APPGL_DCR_SENTINEL_HOOKS must be OFF (was '${appgl_dcr_sentinel_hooks:-unset}')"
    [ "$appgl_log_all" = "OFF" ] \
        || append_failure "APPGL_LOG_ALL must be OFF (was '${appgl_log_all:-unset}')"
    [ "$appgl_log_draw" = "OFF" ] \
        || append_failure "APPGL_LOG_DRAW must be OFF (was '${appgl_log_draw:-unset}')"
    [ "$appgl_log_shader" = "OFF" ] \
        || append_failure "APPGL_LOG_SHADER must be OFF (was '${appgl_log_shader:-unset}')"
    [ "$appgl_log_texture" = "OFF" ] \
        || append_failure "APPGL_LOG_TEXTURE must be OFF (was '${appgl_log_texture:-unset}')"
    [ "$appgl_log_buffer" = "OFF" ] \
        || append_failure "APPGL_LOG_BUFFER must be OFF (was '${appgl_log_buffer:-unset}')"
    [ "$appgl_log_pipeline" = "OFF" ] \
        || append_failure "APPGL_LOG_PIPELINE must be OFF (was '${appgl_log_pipeline:-unset}')"
    [ "$dylib_arch" = "arm64" ] \
        || append_failure "dylib arch must be arm64 (was '$dylib_arch')"
    [ "$dylib_size" -le "$max_size" ] \
        || append_failure "dylib size $dylib_size exceeds APPGL_SHAPE_MAX_SIZE_BYTES=$max_size"
    [ "$nm_m_lines" -le "$max_nm_lines" ] \
        || append_failure "nm -m line count $nm_m_lines exceeds APPGL_SHAPE_MAX_NM_M_LINES=$max_nm_lines"
    [ "$stubs_size" -le "$max_stubs" ] \
        || append_failure "__stubs size $stubs_size exceeds APPGL_SHAPE_MAX_STUBS_BYTES=$max_stubs"
    [ "$linkedit_filesize" -le "$max_linkedit" ] \
        || append_failure "__LINKEDIT filesize $linkedit_filesize exceeds APPGL_SHAPE_MAX_LINKEDIT_FILESIZE=$max_linkedit"

    if [ "${#failures[@]}" -gt 0 ]; then
        release_shape_status="FAIL"
    fi
elif [ "$require_release" -eq 1 ]; then
    release_shape_status="DIAGNOSTIC_OPT_OUT"
fi

created_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
    printf 'schema: appgl-binary-shape-v1\n'
    printf 'created_utc: "%s"\n' "$created_utc"
    [ -z "$artifact_id" ] || printf 'artifact_id: %s\n' "$artifact_id"
    [ -z "$variant" ] || printf 'variant: %s\n' "$variant"
    [ -z "$source_commit" ] || printf 'source_commit: %s\n' "$source_commit"
    [ -z "$parent_commit" ] || printf 'parent_commit: %s\n' "$parent_commit"
    [ -z "$diagnostic_label" ] || printf 'diagnostic_label: "%s"\n' "$diagnostic_label"
    printf 'dylib_path: %s\n' "$dylib"
    printf 'dylib_sha256: %s\n' "$dylib_sha"
    printf 'dylib_uuid: %s\n' "$dylib_uuid"
    printf 'dylib_arch: %s\n' "$dylib_arch"
    printf 'dylib_size_bytes: %s\n' "$dylib_size"
    printf 'file: "%s"\n' "$file_summary"
    printf 'install_name: %s\n' "${install_name:-unknown}"
    printf 'nm_m_lines: %s\n' "$nm_m_lines"
    printf '__stubs_size_bytes: %s\n' "$stubs_size"
    printf '__stubs_size_hex: %s\n' "$stubs_hex"
    printf '__LINKEDIT_filesize: %s\n' "$linkedit_filesize"
    printf '__LINKEDIT_vmsize: %s\n' "$linkedit_vmsize"
    printf 'cmake_cache: %s\n' "${cmake_cache:-unknown}"
    printf 'cmake_build_type: %s\n' "${cmake_build_type:-unknown}"
    printf 'cmake_cxx_flags_release: "%s"\n' "${cmake_cxx_flags_release:-unknown}"
    printf 'cmake_objcxx_flags_release: "%s"\n' "${cmake_objcxx_flags_release:-unknown}"
    printf 'appgl_vendor_third_party: %s\n' "${appgl_vendor_third_party:-unknown}"
    printf 'appgl_fp64_emulation: %s\n' "${appgl_fp64_emulation:-unknown}"
    printf 'appgl_enable_asan: %s\n' "${appgl_enable_asan:-unknown}"
    printf 'appgl_dcr_sentinel_hooks: %s\n' "${appgl_dcr_sentinel_hooks:-unknown}"
    printf 'appgl_log_all: %s\n' "${appgl_log_all:-unknown}"
    printf 'appgl_log_draw: %s\n' "${appgl_log_draw:-unknown}"
    printf 'appgl_log_shader: %s\n' "${appgl_log_shader:-unknown}"
    printf 'appgl_log_texture: %s\n' "${appgl_log_texture:-unknown}"
    printf 'appgl_log_buffer: %s\n' "${appgl_log_buffer:-unknown}"
    printf 'appgl_log_pipeline: %s\n' "${appgl_log_pipeline:-unknown}"
    printf 'release_shape_required: %s\n' "$release_shape_required"
    printf 'release_shape_status: %s\n' "$release_shape_status"
    printf 'threshold_max_size_bytes: %s\n' "$max_size"
    printf 'threshold_max_nm_m_lines: %s\n' "$max_nm_lines"
    printf 'threshold_max_stubs_bytes: %s\n' "$max_stubs"
    printf 'threshold_max_LINKEDIT_filesize: %s\n' "$max_linkedit"
    printf 'release_shape_failures:\n'
    if [ "${#failures[@]}" -eq 0 ]; then
        printf '  - none\n'
    else
        for failure in "${failures[@]}"; do
            printf '  - %s\n' "$failure"
        done
    fi
    printf '\nsize_m:\n'
    printf '%s\n' "$size_m_text"
} > "$out"

if [ "$release_shape_status" = "FAIL" ]; then
    printf 'appgl_binary_shape_report: release-shape gate failed; see %s\n' "$out" >&2
    exit 3
fi
