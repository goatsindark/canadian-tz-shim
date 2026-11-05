#!/usr/bin/env bash
# docker/lxqt/check.sh — LXQt adapter integration checks.
#
# LXQt's clock lives at ~/.config/lxqt/panel.conf. This script seeds
# a realistic multi-plugin panel with one clock, then verifies the
# adapter can rewrite its timezone and restore it.

set -uo pipefail
# shellcheck source=/usr/local/bin/dtp-check-lib
source /usr/local/bin/dtp-check-lib

echo "============================================"
echo " LXQt integration check: lxqt"
echo "============================================"

PANEL="$HOME/.config/lxqt/panel.conf"

# ---------------------------------------------------------------------------
echo ""
echo "== Backend presence =="

if [[ -x /usr/bin/lxqt-panel ]]; then
    pass "lxqt-panel binary available (config path is authoritative)"
    CAP_RECOGNIZED="yes"
else
    fail "lxqt-panel missing"
    print_capability_matrix; exit 1
fi

if [[ -f /usr/share/zoneinfo/Canadian/PCT ]]; then
    pass "Canadian/PCT TZif installed by core"
    CAP_ENUMERATED="yes"
    probe="$(TZ=Canadian/PCT date -d 2026-12-15 +%Z)"
    [[ "$probe" == "PCT" ]] \
        && pass "runtime resolves Canadian/PCT at a fixed date" \
        || fail "runtime did not resolve (got '$probe')"
else
    fail "Canadian/PCT missing"
    print_capability_matrix; exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "== Seed a realistic panel.conf =="

mkdir -p "$(dirname "$PANEL")"
# Match upstream LXQt's shipped default layout: a [panel1] header with
# plugins list, then one section per widget.
cat > "$PANEL" <<'EOF'
panels=panel1

[panel1]
alignment=Left
desktop=0
hideCount=0
iconSize=22
lineCount=1
pluginLimit=0
position=Bottom
reserveSpace=true
showShadow=false
size=22
type=lxqt-panel
worldIconTheme=default
plugins=fancymenu,quicklaunch,desktopswitch,taskbar,clock,tray,showdesktop

[fancymenu]
type=fancymenu

[quicklaunch]
type=quicklaunch

[desktopswitch]
type=desktopswitch

[taskbar]
type=taskbar

[clock]
type=clock
alignment=Right
hformat=1
lformat=LLLT
showDate=true
showSeconds=false
timezone=America/Vancouver

[tray]
type=tray

[showdesktop]
type=showdesktop
EOF
pass "panel.conf seeded with clock timezone=America/Vancouver"

# Selectability — the file format accepts arbitrary ids
grep -q '^timezone=Canadian/PCT$' /dev/null 2>/dev/null  # noop
cp "$PANEL" "$PANEL.test-backup"
sed -i 's|timezone=America/Vancouver|timezone=Canadian/PCT|' "$PANEL"
if grep -q '^timezone=Canadian/PCT$' "$PANEL"; then
    pass "config file format accepts the Canadian/PCT id"
    CAP_SELECTABLE="yes"
else
    fail "config file did not round-trip the id"
fi
mv "$PANEL.test-backup" "$PANEL"

# ---------------------------------------------------------------------------
echo ""
echo "== Dry run makes no writes =="

before=$(md5sum "$PANEL" | awk '{print $1}')
patch_dry lxqt >/dev/null
after=$(md5sum "$PANEL" | awk '{print $1}')
[[ "$before" == "$after" ]] && pass "dry-run: file unchanged" \
    || fail "dry-run mutated the file"

# ---------------------------------------------------------------------------
echo ""
echo "== Apply rewrites the clock timezone =="

patch_apply lxqt >/dev/null
if grep -q '^timezone=Canadian/PCT$' "$PANEL"; then
    pass "adapter rewrote timezone=Canadian/PCT"
    CAP_RENDERS="yes"
else
    fail "adapter did not rewrite; file now: $(grep timezone= "$PANEL")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "== Unrelated INI content preserved =="

# Check other keys in [clock] survived, and other plugin sections intact.
for want in "type=clock" "alignment=Right" "hformat=1" "lformat=LLLT" \
            "showDate=true" "showSeconds=false"; do
    if grep -qxF "$want" "$PANEL"; then
        pass "kept '$want'"
    else
        fail "lost '$want'"
    fi
done

for want in "[fancymenu]" "[quicklaunch]" "[desktopswitch]" "[taskbar]" \
            "[tray]" "[showdesktop]" "type=fancymenu" "type=quicklaunch" "type=tray"; do
    if grep -qxF "$want" "$PANEL"; then
        pass "kept '$want'"
    else
        fail "lost '$want'"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "== Restore =="

patch_restore >/dev/null
if grep -q '^timezone=America/Vancouver$' "$PANEL"; then
    pass "restore returned the original id"
else
    fail "restore left: $(grep timezone= "$PANEL")"
fi

print_capability_matrix
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
