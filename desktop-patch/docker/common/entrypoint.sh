#!/usr/bin/env bash
# common/entrypoint.sh — container entry for the desktop-patch integration
# harness.
#
# Runs the CMD as an unprivileged user, with a private D-Bus session when
# the backend requires it. Never uses host directories, never uses
# --privileged, and never sees the developer's real config.

set -euo pipefail

TEST_USER="${DTP_TEST_USER:-dtp}"
TEST_UID="${DTP_TEST_UID:-2000}"
TEST_HOME="${DTP_TEST_HOME:-/tmp/dtp-home}"

# The container starts as root so we can install custom zones into
# /usr/share/zoneinfo/ once (via install.sh in the Dockerfile), then drop
# privileges for the actual check run.

if ! id -u "$TEST_USER" >/dev/null 2>&1; then
    groupadd -g "$TEST_UID" "$TEST_USER" 2>/dev/null || groupadd "$TEST_USER"
    useradd  -N -u "$TEST_UID" -g "$TEST_UID" -d "$TEST_HOME" -s /bin/bash "$TEST_USER" 2>/dev/null \
        || useradd -m -u "$TEST_UID" -d "$TEST_HOME" -s /bin/bash "$TEST_USER"
fi
mkdir -p "$TEST_HOME"
chown -R "$TEST_UID":"$TEST_UID" "$TEST_HOME"

if [[ "${DTP_NEEDS_DBUS:-0}" == "1" ]]; then
    XDG_RUNTIME_DIR="/run/user/$TEST_UID"
    mkdir -p "$XDG_RUNTIME_DIR"
    chown "$TEST_UID":"$TEST_UID" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    exec setpriv --reuid="$TEST_UID" --regid="$TEST_UID" --clear-groups \
        env HOME="$TEST_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        dbus-run-session -- bash -c "$*"
else
    exec setpriv --reuid="$TEST_UID" --regid="$TEST_UID" --clear-groups \
        env HOME="$TEST_HOME" bash -c "$*"
fi
