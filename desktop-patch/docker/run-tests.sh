#!/usr/bin/env bash
# docker/run-tests.sh — build each container and run its check.
#
# Usage:
#   desktop-patch/docker/run-tests.sh               # all six desktops
#   desktop-patch/docker/run-tests.sh gnome xfce    # subset
#   desktop-patch/docker/run-tests.sh --list        # show targets
#   desktop-patch/docker/run-tests.sh --build-only  # build images, don't run
#
# Requires: docker(1), working `docker build` and `docker run` (rootless
# is fine; sudo is NOT required — the containers use their own isolated
# user).
#
# This script intentionally does not touch the host's home, /etc, or
# /usr. Everything is inside throwaway containers.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/desktop-patch/docker"

ALL_DESKTOPS=(gnome cinnamon mate budgie xfce lxqt)

if [[ ! -x "$(command -v docker 2>/dev/null)" ]] && ! docker --version >/dev/null 2>&1; then
    echo "docker is not installed or not in PATH" >&2
    exit 2
fi

# --- arg handling ---
BUILD_ONLY=0
LIST_ONLY=0
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --list)        LIST_ONLY=1 ;;
        --build-only)  BUILD_ONLY=1 ;;
        --help|-h)
            sed -n '2,15p' "$0"; exit 0 ;;
        *) TARGETS+=("$arg") ;;
    esac
done
if [[ "$LIST_ONLY" == "1" ]]; then
    printf 'Available targets:\n'
    for d in "${ALL_DESKTOPS[@]}"; do printf '  %s\n' "$d"; done
    exit 0
fi
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("${ALL_DESKTOPS[@]}")
fi

# --- build + run ---
declare -A RESULT=()
overall_rc=0

for desktop in "${TARGETS[@]}"; do
    dockerfile="${DOCKER_DIR}/${desktop}/Dockerfile"
    if [[ ! -f "$dockerfile" ]]; then
        echo "skip $desktop (no Dockerfile)"
        RESULT[$desktop]="skipped"
        continue
    fi
    echo ""
    echo "============================================"
    echo " Building tzshim-check-${desktop}"
    echo "============================================"
    if ! docker build -q \
            --build-arg BUILDKIT_INLINE_CACHE=1 \
            -t "tzshim-check-${desktop}" \
            -f "$dockerfile" \
            "$REPO_ROOT"; then
        echo "BUILD FAILED: $desktop"
        RESULT[$desktop]="build-failed"
        overall_rc=1
        continue
    fi
    RESULT[$desktop]="built"
    [[ "$BUILD_ONLY" == "1" ]] && continue

    echo ""
    echo "============================================"
    echo " Running check: $desktop"
    echo "============================================"
    # --network=none blocks network from the check container itself.
    # Do NOT pass --cap-drop=ALL: the entrypoint needs SETUID/SETGID/CHOWN
    # to create an unprivileged user and chown its HOME. Containers are
    # still unprivileged (no --privileged, no --pid=host, no host
    # filesystem binds).
    if docker run --rm \
            --network=none \
            "tzshim-check-${desktop}"; then
        RESULT[$desktop]="PASS"
    else
        rc=$?
        RESULT[$desktop]="FAIL (rc=$rc)"
        overall_rc=1
    fi
done

echo ""
echo "============================================"
echo " Summary"
echo "============================================"
for d in "${TARGETS[@]}"; do
    printf '  %-10s → %s\n' "$d" "${RESULT[$d]:-not-run}"
done

exit "$overall_rc"
