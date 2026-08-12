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

# The two dependencies are handled differently, deliberately:
#
#   SPIRV-Cross carries 19 commits of AppGL work, so it is fetched from a fork
#   with those changes already in its history. The spirv-cross-*.patch files in
#   third_party/patches/ are a provenance record only and are NOT applied.
#
#   glslang carries three small changes across four files, which is too little to
#   justify a fork. It is fetched clean from upstream and patched here. Those
#   patches ARE build inputs — without them the build differs from the one AppGL's
#   conformance results were measured against.
#
# ⚠ Do NOT apply every file in third_party/patches/glslang-*.patch. The
# cull-distance patch is a superset that already contains every change in
# gl-numsamples; applying both fails. gl-numsamples is retained as superseded
# provenance. The two patches listed below reproduce the build tree exactly, and
# the digests are verified after application rather than assumed.

GLSLANG_PATCHES=(
    "glslang-cull-distance-builtin-constants.patch"
    "glslang-vulkanrelaxed-binding-range-check.patch"
)

# sha256 of each patched file, in the order listed. Verified post-application.
GLSLANG_EXPECT=(
    "glslang/MachineIndependent/Initialize.cpp  a8cdc95d946d38f99a41f1eda48cd7f725b8dc27f4ea89ac1eb6081e8be06b80"
    "glslang/MachineIndependent/ParseHelper.cpp b0afa0d27f1c2f24dc62b87e44c04ae31f59793caeb8a8089db411a6bb83fcfe"
    "glslang/MachineIndependent/Versions.cpp    9c53b8075b664b873150396c32423145bbb1fd557604b98fad0c7a2cb32c37ca"
    "glslang/MachineIndependent/Versions.h      f774164de32c98f4e5543d3e78fa4f33ef9ae44a3439c0598121a7e2b7c548ad"
)

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

# apply_glslang_patches
#
# Applies the AppGL changes onto the clean upstream checkout, then verifies the
# result against known digests. Idempotent: if the tree already matches, it does
# nothing. Verification is the point — a patch that applies with fuzz produces a
# tree that is neither upstream nor ours, and silently building it is worse than
# failing here.
apply_glslang_patches() {
    local dest="${THIRD_PARTY}/glslang"
    local patches="${THIRD_PARTY}/patches"

    if verify_glslang; then
        log "glslang: patches already applied and verified"
        return 0
    fi

    for p in "${GLSLANG_PATCHES[@]}"; do
        [ -f "${patches}/${p}" ] || fail "missing patch ${patches}/${p}"
        if git -C "${dest}" apply --check "${patches}/${p}" 2>/dev/null; then
            git -C "${dest}" apply "${patches}/${p}" || fail "glslang: ${p} failed to apply"
            log "glslang: applied ${p}"
        else
            fail "glslang: ${p} does not apply cleanly to the pinned revision"
        fi
    done

    verify_glslang || fail "glslang: patches applied but the result does not match expected digests"
    log "glslang: patched tree verified against expected digests"
}

# verify_glslang — true only if every patched file matches its expected sha256.
verify_glslang() {
    local dest="${THIRD_PARTY}/glslang" entry rel want got
    for entry in "${GLSLANG_EXPECT[@]}"; do
        rel="${entry%% *}"
        want="${entry##* }"
        [ -f "${dest}/${rel}" ] || return 1
        got=$(shasum -a 256 "${dest}/${rel}" 2>/dev/null | cut -d' ' -f1)
        [ "${got}" = "${want}" ] || return 1
    done
    return 0
}

main() {
    [ -d "${REPO_ROOT}/src" ] \
        || fail "cannot locate repository root (no src/ above ${SCRIPT_DIR})"

    mkdir -p "${THIRD_PARTY}"

    echo "Fetching AppGL third-party dependencies into ${THIRD_PARTY}"
    fetch_pinned "SPIRV-Cross" "${SPIRV_CROSS_REPO}" "${SPIRV_CROSS_PIN}"
    fetch_pinned "glslang"     "${GLSLANG_REPO}"     "${GLSLANG_PIN}"
    apply_glslang_patches
    echo "Done. All dependencies verified at their pinned revisions."
}

main "$@"
