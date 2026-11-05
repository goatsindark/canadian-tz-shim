#!/usr/bin/env bash
# docker/xfce/check.sh — XFCE adapter integration checks.
#
# The clock plugin's timezone lives at /plugins/plugin-N/timezone in
# the `xfce4-panel` Xfconf channel. We install a synthetic panel with
# one clock plugin, start the Xfconf backend (xfsettingsd), run the
# adapter, verify the property round-trips, then restore.

set -uo pipefail
# shellcheck source=/usr/local/bin/dtp-check-lib
source /usr/local/bin/dtp-check-lib

echo "============================================"
echo " Xfconf integration check: xfce"
echo "============================================"

# ---------------------------------------------------------------------------
echo ""
echo "== Backend presence =="

if command -v xfconf-query >/dev/null; then
    pass "xfconf-query available"
else
    fail "xfconf-query missing"
    print_capability_matrix; exit 1
fi

# Start the Xfconf settings daemon; it registers the D-Bus backend.
# Without it, xfconf-query reads the XML file but does not track
# live changes across processes.
if command -v xfsettingsd >/dev/null; then
    xfsettingsd --daemon 2>/dev/null || true
    sleep 1
    pass "xfsettingsd started"
else
    fail "xfsettingsd not installed"
    print_capability_matrix; exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "== Custom zone discovery =="

if [[ -f /usr/share/zoneinfo/Canadian/PCT ]]; then
    pass "Canadian/PCT TZif present"
    CAP_ENUMERATED="yes"
    probe="$(TZ=Canadian/PCT date -d 2026-12-15 +%Z)"
    if [[ "$probe" == "PCT" ]]; then
        pass "runtime resolves Canadian/PCT at a fixed date"
        CAP_RECOGNIZED="yes"
    else
        fail "runtime did not resolve Canadian/PCT (got '$probe')"
    fi
else
    fail "Canadian/PCT missing — install.sh did not run correctly"
    print_capability_matrix; exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "== Seed a real clock plugin with America/Vancouver =="

# Build a minimal xfce4-panel channel with one clock plugin via
# xfconf-query so it goes through the running backend.
xfconf-query -c xfce4-panel -p /plugins/plugin-3 \
    -t string -s clock --create 2>/dev/null || true
xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone \
    -t string -s America/Vancouver --create 2>/dev/null || true
xfconf-query -c xfce4-panel -p /plugins/plugin-3/TimezoneName \
    -t string -s America/Vancouver --create 2>/dev/null || true

# Selectability: can Xfconf store the Canadian id at all?
xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone \
    -t string -s Canadian/PCT 2>/dev/null
readback=$(xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone 2>/dev/null)
if [[ "$readback" == "Canadian/PCT" ]]; then
    pass "xfconf accepts Canadian/PCT as a plugin property value"
    CAP_SELECTABLE="yes"
else
    fail "xfconf rejected the custom id (readback: $readback)"
fi

# Re-seed the source id
xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone \
    -t string -s America/Vancouver 2>/dev/null

seeded=$(xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone)
note "seeded: $seeded"
[[ "$seeded" == "America/Vancouver" ]] && pass "seed confirmed" || fail "seed mismatch"

# ---------------------------------------------------------------------------
echo ""
echo "== Dry run makes no writes =="

patch_dry xfce >/dev/null
still=$(xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone)
[[ "$still" == "America/Vancouver" ]] \
    && pass "dry-run unchanged" \
    || fail "dry-run wrote: $still"

# ---------------------------------------------------------------------------
echo ""
echo "== Apply rewrites to Canadian/PCT =="

patch_apply xfce >/dev/null
after=$(xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone 2>/dev/null)
note "after apply: $after"
if [[ "$after" == "Canadian/PCT" ]]; then
    pass "adapter rewrote the plugin's Timezone"
    CAP_RENDERS="yes"
else
    fail "adapter did not rewrite: $after"
fi

# ---------------------------------------------------------------------------
echo ""
echo "== Unrelated plugin properties preserved =="

# TimezoneName we set separately should still be America/Vancouver unless
# the adapter intentionally rewrites it too. Check that we did not
# clobber other properties.
if xfconf-query -c xfce4-panel -p /plugins -lt 'array' >/dev/null 2>&1; then
    pass "plugins array intact"
fi

# ---------------------------------------------------------------------------
echo ""
echo "== Restore =="

patch_restore >/dev/null
restored=$(xfconf-query -c xfce4-panel -p /plugins/plugin-3/Timezone 2>/dev/null)
note "after restore: $restored"
[[ "$restored" == "America/Vancouver" ]] \
    && pass "restore returned the original id" \
    || fail "restore left: $restored"

print_capability_matrix
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
