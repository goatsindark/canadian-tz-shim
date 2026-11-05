#!/usr/bin/env bash
# common/check_lib.sh — shared helpers for every desktop's check script.
#
# Verification target: the specific setting the clock widget reads, not the
# whole desktop. A check is "integration verified" when:
#   - The real schema/tool is installed inside the container.
#   - desktop-patch reads the seeded value.
#   - desktop-patch dry-run writes nothing.
#   - desktop-patch apply writes exactly one setting.
#   - desktop-patch verify confirms the new id.
#   - desktop-patch restore returns the previous id.

PASS=0
FAIL=0
DESKTOP_ID="${DESKTOP_ID:-unknown}"

CAP_RECOGNIZED="no"      # the desktop's own runtime accepts the id
CAP_ENUMERATED="no"      # the desktop lists it in its available zones
CAP_SELECTABLE="no"      # desktop-patch can select it programmatically
CAP_RENDERS="no"         # the desktop's clock path resolves it to PCT
CAP_VALIDATION="fixture" # upgraded to "integration" by the caller

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
note() { echo "  → $1"; }

print_capability_matrix() {
    echo ""
    echo "== Capability report: $DESKTOP_ID =="
    printf '  recognized:                    %s\n' "$CAP_RECOGNIZED"
    printf '  enumerated:                    %s\n' "$CAP_ENUMERATED"
    printf '  selectable:                    %s\n' "$CAP_SELECTABLE"
    printf '  renders_expected_abbreviation: %s\n' "$CAP_RENDERS"
    printf '  validation_level:              %s\n' "$CAP_VALIDATION"
    printf '  checks: %d passed, %d failed\n' "$PASS" "$FAIL"
    echo "==============================="
}

REPO_DIR="${REPO_DIR:-/opt/canadian-tz-shim}"
PATCH_BIN="$REPO_DIR/desktop-patch/desktop-patch.sh"

# gsettings-based helper (GNOME, Cinnamon, MATE, Budgie)
gsettings_read()  { gsettings get "$1" "$2" 2>/dev/null || echo ""; }
gsettings_write() { gsettings set "$1" "$2" "$3" 2>/dev/null; }
gsettings_exists() { gsettings list-keys "$1" 2>/dev/null >/dev/null; }
gsettings_has_key() { gsettings list-keys "$1" 2>/dev/null | grep -qx "$2"; }

# Canonical run of the desktop-patch apply + restore, feeding "y" to
# any confirmation prompt.
patch_apply() {
    local desktop="$1"; shift
    printf 'y\n' | "$PATCH_BIN" --desktop "$desktop" "$@" 2>&1 | tee /tmp/dtp-apply.log
}
patch_dry()  { "$PATCH_BIN" --desktop "$1" --dry-run </dev/null 2>&1 | tee /tmp/dtp-dry.log; }
patch_restore() { printf 'y\n' | "$PATCH_BIN" --restore 2>&1 | tee /tmp/dtp-restore.log; }
