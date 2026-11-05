#!/usr/bin/env bash
# Canadian Timezone Shim - Test Isolation Guard
# Asserts that running each suite never creates, modifies, or deletes anything
# in the developer's real home directory or system installation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SUITES=(test.sh test-regressions.sh test-upgrade.sh test-uninstall-edge-cases.sh
        test-custom-zones.sh test-migration.sh)

TOTAL=0
PASSED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; }
info() { echo -e "${YELLOW}→${NC} $1"; }

# Paths a shim run may legitimately create in a user's home. If any of these
# appear (or vanish) during a test run, the suite leaked into the real account.
WATCH_PATHS=(
    "$HOME/.tzinfo"
    "$HOME/.zoneinfo"
    "$HOME/.config/tzshim.conf"
    "$HOME/.local/state/canadian-tz-shim"
)

snapshot() {
    # Records existence + content hash for each watched path
    local p
    for p in "${WATCH_PATHS[@]}"; do
        if [[ -e "$p" ]]; then
            if [[ -f "$p" ]]; then
                echo "F $(md5sum "$p" 2>/dev/null | cut -d' ' -f1) $p"
            else
                echo "D $(find "$p" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d' ' -f1) $p"
            fi
        else
            echo "- $p"
        fi
    done
}

# Guard: refuse to run as root, where "the real home" is a system location
if [[ $EUID -eq 0 ]]; then
    echo "This guard must run unprivileged (it protects the current user's home)." >&2
    exit 2
fi

echo "========================================"
echo "Canadian Timezone Shim - Test Isolation Guard"
echo "========================================"
echo "Protected HOME: $HOME"
echo

BEFORE=$(snapshot)
LOCALTIME_BEFORE=$(readlink /etc/localtime 2>/dev/null || echo "")
CONF_BEFORE=$(md5sum /etc/tzshim.conf 2>/dev/null | cut -d' ' -f1 || echo "")

for suite in "${SUITES[@]}"; do
    if [[ ! -f "$suite" ]]; then
        info "skipping absent suite: $suite"
        continue
    fi
    info "running $suite"
    TOTAL=$((TOTAL + 1))
    if timeout 300 bash "$suite" >/dev/null 2>&1; then
        suite_rc=0
    else
        suite_rc=$?
    fi

    AFTER=$(snapshot)
    if [[ "$BEFORE" != "$AFTER" ]]; then
        fail "$suite modified the real home directory"
        diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/    /'
        exit 1
    fi

    if [[ $suite_rc -ne 0 ]]; then
        fail "$suite exited with status $suite_rc"
        exit 1
    fi
    pass "$suite completed with no real-home mutation"
done

# System installation must be untouched as well
LOCALTIME_AFTER=$(readlink /etc/localtime 2>/dev/null || echo "")
CONF_AFTER=$(md5sum /etc/tzshim.conf 2>/dev/null | cut -d' ' -f1 || echo "")
TOTAL=$((TOTAL + 1))
if [[ "$LOCALTIME_BEFORE" == "$LOCALTIME_AFTER" && "$CONF_BEFORE" == "$CONF_AFTER" ]]; then
    pass "/etc/localtime and /etc/tzshim.conf unchanged"
else
    fail "system installation was modified by the test run"
    exit 1
fi

echo
echo "========================================"
echo "Isolation Summary: $PASSED/$TOTAL checks passed"
echo "========================================"
if [[ "$PASSED" -eq "$TOTAL" ]]; then
    echo -e "${GREEN}Test suites are properly isolated.${NC}"
    exit 0
fi
echo -e "${RED}Isolation failure detected.${NC}"
exit 1
