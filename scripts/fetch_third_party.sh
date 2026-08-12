#!/usr/bin/env bash
#
# fetch_third_party.sh — populate third_party/ at the pinned revisions.
#
# AppGL does not vendor its third-party dependencies into this repository; it
# fetches them at exact pinned commits. This script is the only supported way to
# populate third_party/, and the pins below are the ones the build is known to
# work against.
#
# Idempotent: re-running against an already-correct tree is a no-op.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pins. Change these deliberately — a build against different revisions has not
# been tested and should not be assumed equivalent.
# ---------------------------------------------------------------------------

SPIRV_CROSS_REPO="${APPGL_SPIRV_CROSS_REPO:-https://github.com/feederbrian/SPIRV-Cross.git}"
SPIRV_CROSS_PIN="601164c16ba27c8f375277115fa719c22b58ed71"

GLSLANG_REPO="${APPGL_GLSLANG_REPO:-https://github.com/KhronosGroup/glslang.git}"
GLSLANG_PIN="dcf1aaa6fd7dc2081f17aa0a4f1590a76473d961"

# SPIRV-Cross is fetched from a fork, not from upstream Khronos. The fork carries
# AppGL-specific fixes that have not been upstreamed. third_party/patches/ holds
# those changes in patch form as a provenance record; they are NOT applied by
# this script and are not build inputs. The fork is the build input.

# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
THIRD_PARTY="${REPO_ROOT}/third_party"

log()  { printf '  %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "git not found on PATH"

# fetch_pinned <name> <repo-url> <commit-sha>
#
# Fetches exactly one commit into a bare-ish working clone at third_party/<name>.
# Uses a targeted fetch rather than a full clone so history is not downloaded.
fetch_pinned() {
    local name="$1" url="$2" pin="$3"
    local dest="${THIRD_PARTY}/${name}"

    if [ -e "${dest}" ] && [ ! -d "${dest}/.git" ]; then
        fail "${dest} exists but is not a git checkout. Remove it and re-run."
    fi

    if [ -d "${dest}/.git" ]; then
        local have
        have="$(git -C "${dest}" rev-parse HEAD 2>/dev/null || echo none)"
        if [ "${have}" = "${pin}" ]; then
            log "${name}: already at ${pin:0:12} — nothing to do"
            return 0
        fi
        log "${name}: at ${have:0:12}, want ${pin:0:12} — updating"
    else
        log "${name}: fetching ${pin:0:12}"
        mkdir -p "${dest}"
        git -C "${dest}" init --quiet
        git -C "${dest}" remote add origin "${url}"
    fi

    # Some servers refuse to serve an arbitrary SHA directly. Try the cheap path
    # first, then fall back to fetching the default branch and checking out.
    if ! git -C "${dest}" fetch --quiet --depth 1 origin "${pin}" 2>/dev/null; then
        log "${name}: server refused single-commit fetch, falling back to full fetch"
        git -C "${dest}" fetch --quiet origin
    fi

    git -C "${dest}" checkout --quiet --detach "${pin}" \
        || fail "${name}: commit ${pin} not found in ${url}"

    # Verify rather than assume: a checkout that silently landed elsewhere is
    # exactly the failure this script exists to prevent.
    local got
    got="$(git -C "${dest}" rev-parse HEAD)"
    [ "${got}" = "${pin}" ] || fail "${name}: expected ${pin}, got ${got}"

    log "${name}: verified at ${pin:0:12}"
}

main() {
    [ -d "${REPO_ROOT}/src" ] \
        || fail "cannot locate repository root (no src/ above ${SCRIPT_DIR})"

    mkdir -p "${THIRD_PARTY}"

    echo "Fetching AppGL third-party dependencies into ${THIRD_PARTY}"
    fetch_pinned "SPIRV-Cross" "${SPIRV_CROSS_REPO}" "${SPIRV_CROSS_PIN}"
    fetch_pinned "glslang"     "${GLSLANG_REPO}"     "${GLSLANG_PIN}"
    echo "Done. All dependencies verified at their pinned revisions."
}

main "$@"
