#!/usr/bin/env bash
# Canadian Timezone Shim - Desktop Patch Test Suite
# Comprehensive tests for the desktop-patch utility

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DESKTOP_PATCH_DIR="${REPO_DIR}/desktop-patch"

# Isolated sandbox
REAL_HOME="${HOME}"
SANDBOX_ROOT="$(mktemp -d "/tmp/desktop-patch-sandbox-XXXXXX")"
export HOME="${SANDBOX_ROOT}/home"
mkdir -p "$HOME"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

info() {
    echo -e "${YELLOW}→${NC} $1"
}

header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Cleanup
sandbox_cleanup() {
    case "$SANDBOX_ROOT" in
        /tmp/desktop-patch-sandbox-*) rm -rf -- "$SANDBOX_ROOT" ;;
        *) echo "REFUSING to remove unexpected sandbox path: $SANDBOX_ROOT" >&2 ;;
    esac
}
trap sandbox_cleanup EXIT

# Hard guard
case "$HOME" in
    "$REAL_HOME")
        echo "FATAL: user-mode tests must not run against the real HOME ($REAL_HOME)" >&2
        exit 1
        ;;
esac

# ============================================================================
# Test Fixtures
# ============================================================================

create_kde_fixture() {
    local fixture_dir="$1"
    mkdir -p "$fixture_dir/.config"
    
    # Create a realistic Plasma 5 appletsrc
    cat > "$fixture_dir/.config/plasma-org.kde.plasma.desktop-appletsrc" <<'EOF'
[Containments][1]
activityId=
formfactor=0
immutability=1
lastScreen=0
wallpaperplugin=org.kde.image

[Containments][1][Wallpaper][org.kde.image][General]
Image=

[Containments][2]
activityId=
formfactor=2
immutability=1
lastScreen=0
wallpaperplugin=

[Containments][2][Applets][3]
geometry=0,0,200,40
immutability=1
plugin=org.kde.plasma.digitalclock

[Containments][2][Applets][3][Configuration]
PreloadWeight=42
showDate=true
showYear=false
TimeZoneId=America/Los_Angeles

[Containments][2][Applets][4]
geometry=200,0,200,40
immutability=1
plugin=org.kde.plasma.systemtray

[Containments][2][Applets][4][Configuration]
PreloadWeight=42

[Containments][2][Applets][5]
geometry=400,0,200,40
immutability=1
plugin=org.kde.plasma.digitalclock

[Containments][2][Applets][5][Configuration]
PreloadWeight=42
showDate=true
TimeZoneId=UTC
EOF
    
    echo "$fixture_dir/.config/plasma-org.kde.plasma.desktop-appletsrc"
}

create_kde_plasma6_fixture() {
    local fixture_dir="$1"
    mkdir -p "$fixture_dir/.config"
    
    # Plasma 6 uses similar format
    cat > "$fixture_dir/.config/plasma-org.kde.plasma.desktop-appletsrc" <<'EOF'
[Containments][1]
activityId=
formfactor=0
immutability=1
lastScreen=0

[Containments][1][Applets][2]
geometry=0,0,200,40
immutability=1
plugin=org.kde.plasma.digitalclock

[Containments][1][Applets][2][Configuration]
TimeZoneId=America/Vancouver
EOF
    
    echo "$fixture_dir/.config/plasma-org.kde.plasma.desktop-appletsrc"
}

create_lxqt_fixture() {
    local fixture_dir="$1"
    mkdir -p "$fixture_dir/.config/lxqt"

    # Real LXQt panel.conf layout: top-level widget sections with type=
    # inside each, and the clock widget's timezone directly in its
    # section. This mirrors what lxqt-panel actually ships and writes.
    cat > "$fixture_dir/.config/lxqt/panel.conf" <<'EOF'
panels=panel1

[panel1]
alignment=Left
desktop=0
iconSize=16
lineCount=1
pluginLimit=0
position=Bottom
reserveSpace=true
showShadow=false
size=22
type=lxqt-panel
plugins=mainmenu,quicklaunch,clock,tray

[mainmenu]
type=mainmenu
showIconMenu=true

[quicklaunch]
type=quicklaunch

[clock]
type=clock
alignment=Right
hformat=1
showDate=true
showSeconds=false
timezone=America/Los_Angeles

[tray]
type=tray
EOF

    echo "$fixture_dir/.config/lxqt/panel.conf"
}

create_xfce_fixture() {
    local fixture_dir="$1"
    # XFCE uses xfconf, but we can test with mock data
    mkdir -p "$fixture_dir/.config/xfce4/xfconf"
    
    # Create a mock xfconf channel file
    cat > "$fixture_dir/.config/xfce4/xfconf/xfce4-panel.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="1"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugins" type="empty">
      <property name="plugin-1" type="string" value="applicationsmenu"/>
      <property name="plugin-2" type="string" value="tasklist"/>
      <property name="plugin-3" type="string" value="clock">
        <property name="Timezone" type="string" value="America/Los_Angeles"/>
      </property>
    </property>
  </property>
</channel>
EOF
    
    echo "$fixture_dir/.config/xfce4/xfconf/xfce4-panel.xml"
}

# ============================================================================
# Tests
# ============================================================================

header "Desktop Patch Test Suite"
echo ""

# ---------------------------------------------------------------------------
# Test: Sandbox isolation
# ---------------------------------------------------------------------------
info "Test: Sandbox isolation - real home is untouched"
if [[ "$HOME" != "$REAL_HOME" ]]; then
    pass "Tests run in isolated sandbox"
else
    fail "Tests are NOT running in isolated sandbox"
fi

# ---------------------------------------------------------------------------
# Test: Script structure
# ---------------------------------------------------------------------------
header "Script Structure Tests"

info "Test: desktop-patch.sh exists and is executable"
if [[ -x "$DESKTOP_PATCH_DIR/desktop-patch.sh" ]]; then
    pass "desktop-patch.sh is executable"
else
    fail "desktop-patch.sh is not executable"
fi

info "Test: All shared components exist"
all_exist=true
for f in detection.sh backup.sh manifest.sh verification.sh ui.sh; do
    if [[ ! -f "$DESKTOP_PATCH_DIR/shared/$f" ]]; then
        all_exist=false
        fail "Missing shared component: $f"
    fi
done
if $all_exist; then
    pass "All shared components exist"
fi

info "Test: All backends exist"
all_exist=true
for f in kconfig.sh gsettings.sh xfconf.sh lxqt.sh; do
    if [[ ! -f "$DESKTOP_PATCH_DIR/backends/$f" ]]; then
        all_exist=false
        fail "Missing backend: $f"
    fi
done
if $all_exist; then
    pass "All backends exist"
fi

info "Test: All adapters exist"
all_exist=true
for f in kde.sh gnome.sh cinnamon.sh xfce.sh mate.sh budgie.sh lxqt.sh; do
    if [[ ! -f "$DESKTOP_PATCH_DIR/adapters/$f" ]]; then
        all_exist=false
        fail "Missing adapter: $f"
    fi
done
if $all_exist; then
    pass "All adapters exist"
fi

# ---------------------------------------------------------------------------
# Test: Help flag
# ---------------------------------------------------------------------------
header "Help and Usage Tests"

info "Test: --help flag works"
if "$DESKTOP_PATCH_DIR/desktop-patch.sh" --help 2>&1 | grep -q "USAGE"; then
    pass "--help flag works"
else
    fail "--help flag does not work"
fi

# ---------------------------------------------------------------------------
# Test: Refuse to run as root
# ---------------------------------------------------------------------------
header "Safety Tests"

info "Test: Refuses to run as root (simulated)"
# We can't actually run as root, but we can check the function exists
# check_not_root is defined in the main script, not in ui.sh
if grep -q "check_not_root" "$DESKTOP_PATCH_DIR/desktop-patch.sh"; then
    pass "check_not_root function exists in main script"
else
    fail "check_not_root function missing from main script"
fi

# ---------------------------------------------------------------------------
# Test: Detection
# ---------------------------------------------------------------------------
header "Detection Tests"

info "Test: Detection with XDG_CURRENT_DESKTOP=KDE"
source "$DESKTOP_PATCH_DIR/shared/detection.sh"
# Clear other desktop env vars to isolate the test
unset XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
XDG_CURRENT_DESKTOP=KDE detect_desktop_environment
if [[ "$DETECTED_DESKTOP" == "kde" ]]; then
    pass "KDE detected from XDG_CURRENT_DESKTOP"
else
    fail "KDE not detected (got: $DETECTED_DESKTOP)"
fi

info "Test: Detection with XDG_CURRENT_DESKTOP=GNOME"
unset XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
XDG_CURRENT_DESKTOP=GNOME detect_desktop_environment
if [[ "$DETECTED_DESKTOP" == "gnome" ]]; then
    pass "GNOME detected from XDG_CURRENT_DESKTOP"
else
    fail "GNOME not detected (got: $DETECTED_DESKTOP)"
fi

info "Test: Detection with XDG_CURRENT_DESKTOP=X-Cinnamon"
unset XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
XDG_CURRENT_DESKTOP=X-Cinnamon detect_desktop_environment
if [[ "$DETECTED_DESKTOP" == "cinnamon" ]]; then
    pass "Cinnamon detected from XDG_CURRENT_DESKTOP"
else
    fail "Cinnamon not detected (got: $DETECTED_DESKTOP)"
fi

info "Test: Detection with XDG_CURRENT_DESKTOP=XFCE"
unset XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
XDG_CURRENT_DESKTOP=XFCE detect_desktop_environment
if [[ "$DETECTED_DESKTOP" == "xfce" ]]; then
    pass "XFCE detected from XDG_CURRENT_DESKTOP"
else
    fail "XFCE not detected (got: $DETECTED_DESKTOP)"
fi

info "Test: Detection with XDG_CURRENT_DESKTOP=MATE"
unset XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
XDG_CURRENT_DESKTOP=MATE detect_desktop_environment
if [[ "$DETECTED_DESKTOP" == "mate" ]]; then
    pass "MATE detected from XDG_CURRENT_DESKTOP"
else
    fail "MATE not detected (got: $DETECTED_DESKTOP)"
fi

info "Test: Detection with XDG_CURRENT_DESKTOP=Budgie:GNOME"
unset XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
XDG_CURRENT_DESKTOP=Budgie:GNOME detect_desktop_environment
if [[ "$DETECTED_DESKTOP" == "budgie" ]]; then
    pass "Budgie detected from XDG_CURRENT_DESKTOP"
else
    fail "Budgie not detected (got: $DETECTED_DESKTOP)"
fi

info "Test: Detection with XDG_CURRENT_DESKTOP=LXQt"
unset XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
XDG_CURRENT_DESKTOP=LXQt detect_desktop_environment
if [[ "$DETECTED_DESKTOP" == "lxqt" ]]; then
    pass "LXQt detected from XDG_CURRENT_DESKTOP"
else
    fail "LXQt not detected (got: $DETECTED_DESKTOP)"
fi

info "Test: Detection with no desktop set"
unset XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION 2>/dev/null || true
if ! detect_desktop_environment; then
    pass "No desktop detected when env vars are unset"
else
    fail "Desktop detected when env vars are unset (got: $DETECTED_DESKTOP)"
fi

# ---------------------------------------------------------------------------
# Test: KDE KConfig backend
# ---------------------------------------------------------------------------
header "KDE KConfig Backend Tests"

source "$DESKTOP_PATCH_DIR/shared/backup.sh"
source "$DESKTOP_PATCH_DIR/backends/kconfig.sh"

info "Test: Find Plasma config"
fixture_dir="${SANDBOX_ROOT}/fixtures/kde"
config_file=$(create_kde_fixture "$fixture_dir")
found=$(find_plasma_config "$fixture_dir/.config")
if [[ "$found" == "$config_file" ]]; then
    pass "Found Plasma config file"
else
    fail "Did not find Plasma config file (got: $found)"
fi

info "Test: Find clock applets"
applets=$(find_clock_applets "$config_file")
count=$(echo "$applets" | grep -c "Containments" || true)
if [[ "$count" -ge 2 ]]; then
    pass "Found $count clock applets"
else
    fail "Expected at least 2 clock applets, found $count"
fi

info "Test: Read KConfig value"
tz=$(read_kconfig_value "$config_file" "Containments][2][Applets][3][Configuration" "TimeZoneId")
if [[ "$tz" == "America/Los_Angeles" ]]; then
    pass "Read TimeZoneId correctly"
else
    fail "TimeZoneId read failed (got: '$tz')"
fi

info "Test: Write KConfig value atomically"
backup_dir="${SANDBOX_ROOT}/backups/kde"
mkdir -p "$backup_dir"
backup_path=$(write_kconfig_value "$config_file" "Containments][2][Applets][3][Configuration" "TimeZoneId" "America/Vancouver" "$backup_dir")
if [[ -f "$backup_path" ]]; then
    pass "Backup created at $backup_path"
else
    fail "Backup not created"
fi

new_tz=$(read_kconfig_value "$config_file" "Containments][2][Applets][3][Configuration" "TimeZoneId")
if [[ "$new_tz" == "America/Vancouver" ]]; then
    pass "TimeZoneId written correctly"
else
    fail "TimeZoneId write failed (got: '$new_tz')"
fi

info "Test: Unrelated content preserved"
# Check that other applets are untouched
other_tz=$(read_kconfig_value "$config_file" "Containments][2][Applets][5][Configuration" "TimeZoneId")
if [[ "$other_tz" == "UTC" ]]; then
    pass "Unrelated applet preserved"
else
    fail "Unrelated applet was modified (got: '$other_tz')"
fi

info "Test: Backup integrity"
if cmp -s "$backup_path" "$fixture_dir/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null; then
    # Backup should NOT match current (current was modified)
    fail "Backup matches current file (should differ)"
else
    pass "Backup differs from current (as expected after modification)"
fi

info "Test: Restore from backup"
cp "$backup_path" "$config_file"
restored_tz=$(read_kconfig_value "$config_file" "Containments][2][Applets][3][Configuration" "TimeZoneId")
if [[ "$restored_tz" == "America/Los_Angeles" ]]; then
    pass "Restored from backup correctly"
else
    fail "Restore from backup failed (got: '$restored_tz')"
fi

# ---------------------------------------------------------------------------
# Test: KDE Plasma 6 fixture
# ---------------------------------------------------------------------------
header "KDE Plasma 6 Tests"

info "Test: Plasma 6 fixture"
fixture_dir6="${SANDBOX_ROOT}/fixtures/kde6"
config_file6=$(create_kde_plasma6_fixture "$fixture_dir6")
applets6=$(find_clock_applets "$config_file6")
if echo "$applets6" | grep -q "Containments"; then
    pass "Found clock applet in Plasma 6 fixture"
else
    fail "No clock applet found in Plasma 6 fixture"
fi

tz6=$(read_kconfig_value "$config_file6" "Containments][1][Applets][2][Configuration" "TimeZoneId")
if [[ "$tz6" == "America/Vancouver" ]]; then
    pass "Plasma 6 fixture has correct timezone"
else
    fail "Plasma 6 fixture timezone incorrect (got: '$tz6')"
fi

# ---------------------------------------------------------------------------
# Test: LXQt backend
# ---------------------------------------------------------------------------
header "LXQt Backend Tests"

source "$DESKTOP_PATCH_DIR/backends/lxqt.sh"

info "Test: Find LXQt panel config"
fixture_dir_lxqt="${SANDBOX_ROOT}/fixtures/lxqt"
config_file_lxqt=$(create_lxqt_fixture "$fixture_dir_lxqt")
found_lxqt=$(find_lxqt_panel_config "$fixture_dir_lxqt/.config/lxqt")
if [[ "$found_lxqt" == "$config_file_lxqt" ]]; then
    pass "Found LXQt panel config"
else
    fail "Did not find LXQt panel config (got: $found_lxqt)"
fi

info "Test: Find LXQt clock widgets"
widgets=$(find_lxqt_clock_widgets "$config_file_lxqt")
if [[ -n "$widgets" ]] && echo "$widgets" | grep -q "clock"; then
    pass "Found clock widget in LXQt fixture"
else
    fail "No clock widget found in LXQt fixture (got: '$widgets')"
fi

info "Test: Read LXQt value"
tz_lxqt=$(read_lxqt_value "$config_file_lxqt" "clock" "timezone")
if [[ "$tz_lxqt" == "America/Los_Angeles" ]]; then
    pass "Read LXQt timezone correctly"
else
    fail "LXQt timezone read failed (got: '$tz_lxqt')"
fi

info "Test: Write LXQt value atomically"
backup_dir_lxqt="${SANDBOX_ROOT}/backups/lxqt"
mkdir -p "$backup_dir_lxqt"
backup_path_lxqt=$(write_lxqt_value "$config_file_lxqt" "clock" "timezone" "America/Vancouver" "$backup_dir_lxqt")
if [[ -f "$backup_path_lxqt" ]]; then
    pass "LXQt backup created"
else
    fail "LXQt backup not created"
fi

new_tz_lxqt=$(read_lxqt_value "$config_file_lxqt" "clock" "timezone")
if [[ "$new_tz_lxqt" == "America/Vancouver" ]]; then
    pass "LXQt timezone written correctly"
else
    fail "LXQt timezone write failed (got: '$new_tz_lxqt')"
fi

info "Test: LXQt unrelated content preserved"
# Other widget sections must be byte-for-byte untouched
type_mainmenu=$(read_lxqt_value "$config_file_lxqt" "mainmenu" "type")
if [[ "$type_mainmenu" == "mainmenu" ]]; then
    pass "Unrelated LXQt widget type preserved"
else
    fail "Unrelated LXQt widget type was modified (got: '$type_mainmenu')"
fi
showdate=$(read_lxqt_value "$config_file_lxqt" "clock" "showDate")
if [[ "$showdate" == "true" ]]; then
    pass "Sibling key inside the widget's own section preserved"
else
    fail "Sibling key inside [clock] was modified (got: '$showdate')"
fi
panel_type=$(read_lxqt_value "$config_file_lxqt" "panel1" "type")
if [[ "$panel_type" == "lxqt-panel" ]]; then
    pass "Panel section type preserved"
else
    fail "Panel section type was modified (got: '$panel_type')"
fi

# ---------------------------------------------------------------------------
# Test: Manifest
# ---------------------------------------------------------------------------
header "Manifest Tests"

source "$DESKTOP_PATCH_DIR/shared/manifest.sh"

info "Test: Create manifest"
state_dir="${SANDBOX_ROOT}/state"
manifest=$(init_manifest "$state_dir" "kde" "5.27" "wayland" "America/Vancouver" "kconfig")
if [[ -f "$manifest" ]]; then
    pass "Manifest created"
else
    fail "Manifest not created"
fi

info "Test: Manifest is valid JSON"
if python3 -c "import json; json.load(open('$manifest'))" 2>/dev/null; then
    pass "Manifest is valid JSON"
else
    fail "Manifest is not valid JSON"
fi

info "Test: Add change to manifest"
add_manifest_change "$manifest" "file" "/test/path:section:key" "old_value" "new_value" "/test/backup"
if python3 -c "
import json
with open('$manifest') as f:
    d = json.load(f)
assert len(d['changes']) == 1
assert d['changes'][0]['target'] == '/test/path:section:key'
" 2>/dev/null; then
    pass "Change added to manifest"
else
    fail "Change not added to manifest"
fi

info "Test: Finalize manifest"
finalize_manifest "$manifest" "success" "true" "false"
if python3 -c "
import json
with open('$manifest') as f:
    d = json.load(f)
assert d['verification'] == 'success'
assert d['reload_recommended'] == True
assert d['reload_performed'] == False
" 2>/dev/null; then
    pass "Manifest finalized"
else
    fail "Manifest not finalized correctly"
fi

info "Test: List manifests"
manifests=$(list_manifests "$state_dir" "kde")
if [[ -n "$manifests" ]]; then
    pass "Listed manifests for kde"
else
    fail "No manifests listed"
fi

# ---------------------------------------------------------------------------
# Test: Backup
# ---------------------------------------------------------------------------
header "Backup Tests"

info "Test: Create backup"
test_file="${SANDBOX_ROOT}/test-backup-file"
echo "test content" > "$test_file"
backup_dir_test="${SANDBOX_ROOT}/test-backups"
bp=$(backup_file "$test_file" "$backup_dir_test")
if [[ -f "$bp" ]] && cmp -s "$test_file" "$bp"; then
    pass "Backup created and matches original"
else
    fail "Backup creation failed"
fi

info "Test: Backup of non-existent file fails"
if backup_file "/nonexistent/file" "$backup_dir_test" 2>/dev/null; then
    fail "Backup of non-existent file should fail"
else
    pass "Backup of non-existent file correctly fails"
fi

# ---------------------------------------------------------------------------
# Test: Dry run
# ---------------------------------------------------------------------------
header "Dry Run Tests"

info "Test: Dry run flag parsing"
if "$DESKTOP_PATCH_DIR/desktop-patch.sh" --desktop kde --dry-run --help 2>&1 | grep -q "dry-run"; then
    pass "Dry run flag is documented"
else
    fail "Dry run flag not documented"
fi

# ---------------------------------------------------------------------------
# Test: Idempotency
# ---------------------------------------------------------------------------
header "Idempotency Tests"

info "Test: KDE write is idempotent"
# Write same value again
backup_dir_idem="${SANDBOX_ROOT}/backups/idem"
mkdir -p "$backup_dir_idem"
write_kconfig_value "$config_file" "Containments][2][Applets][3][Configuration" "TimeZoneId" "America/Vancouver" "$backup_dir_idem" >/dev/null
tz_after=$(read_kconfig_value "$config_file" "Containments][2][Applets][3][Configuration" "TimeZoneId")
if [[ "$tz_after" == "America/Vancouver" ]]; then
    pass "Idempotent write preserves value"
else
    fail "Idempotent write changed value (got: '$tz_after')"
fi

# ---------------------------------------------------------------------------
# Test: Multiple clock applets
# ---------------------------------------------------------------------------
header "Multiple Clock Applets Tests"

info "Test: Multiple KDE clock applets detected"
applets=$(find_clock_applets "$config_file")
count=$(echo "$applets" | grep -c "Containments" || true)
if [[ "$count" -ge 2 ]]; then
    pass "Multiple clock applets detected ($count)"
else
    fail "Expected multiple clock applets, found $count"
fi

# ---------------------------------------------------------------------------
# Test: Paths with spaces
# ---------------------------------------------------------------------------
header "Path Safety Tests"

info "Test: Paths with spaces"
space_dir="${SANDBOX_ROOT}/path with spaces"
mkdir -p "$space_dir/.config"
# Create a fresh fixture for this test (not the modified one from earlier)
create_kde_fixture "$space_dir" >/dev/null
space_config="$space_dir/.config/plasma-org.kde.plasma.desktop-appletsrc"
found_space=$(find_plasma_config "$space_dir/.config")
if [[ "$found_space" == "$space_config" ]]; then
    pass "Handles paths with spaces"
else
    fail "Failed with paths with spaces (got: '$found_space')"
fi

space_tz=$(read_kconfig_value "$space_config" "Containments][2][Applets][3][Configuration" "TimeZoneId")
if [[ "$space_tz" == "America/Los_Angeles" ]]; then
    pass "Reads values from paths with spaces"
else
    fail "Failed to read from paths with spaces (got: '$space_tz')"
fi

# ---------------------------------------------------------------------------
# Test: Refuse to patch multiple desktops
# ---------------------------------------------------------------------------
header "Single Desktop Tests"

info "Test: Only one desktop per invocation"
# The script only accepts one --desktop argument
if "$DESKTOP_PATCH_DIR/desktop-patch.sh" --help 2>&1 | grep -q "\-\-desktop DESKTOP"; then
    pass "Script accepts single --desktop argument"
else
    fail "Script does not accept --desktop argument"
fi

# ---------------------------------------------------------------------------
# Test: Interrupted write safety
# ---------------------------------------------------------------------------
header "Interrupted Write Safety Tests"

info "Test: Atomic write leaves original on failure"
# Create a file and try to write to a non-existent section
test_atomic="${SANDBOX_ROOT}/atomic-test"
cp "$fixture_dir/.config/plasma-org.kde.plasma.desktop-appletsrc" "$test_atomic"
before_hash=$(md5sum "$test_atomic" | cut -d' ' -f1)

# Try to write to non-existent section - should fail
atomic_backup="${SANDBOX_ROOT}/backups/atomic"
mkdir -p "$atomic_backup"
if write_kconfig_value "$test_atomic" "NonExistent][Section" "key" "value" "$atomic_backup" 2>/dev/null; then
    fail "Write to non-existent section should fail"
else
    after_hash=$(md5sum "$test_atomic" | cut -d' ' -f1)
    if [[ "$before_hash" == "$after_hash" ]]; then
        pass "File unchanged after failed write"
    else
        fail "File was modified by failed write"
    fi
fi

# ---------------------------------------------------------------------------
# Test: XFCE fixture
# ---------------------------------------------------------------------------
header "XFCE Fixture Tests"

info "Test: XFCE fixture created"
fixture_dir_xfce="${SANDBOX_ROOT}/fixtures/xfce"
xfce_config=$(create_xfce_fixture "$fixture_dir_xfce")
if [[ -f "$xfce_config" ]]; then
    pass "XFCE fixture created"
else
    fail "XFCE fixture not created"
fi

# ---------------------------------------------------------------------------
# Test: Adapter functions exist
# ---------------------------------------------------------------------------
header "Adapter Function Tests"

source "$DESKTOP_PATCH_DIR/adapters/kde.sh"
source "$DESKTOP_PATCH_DIR/adapters/gnome.sh"
source "$DESKTOP_PATCH_DIR/adapters/cinnamon.sh"
source "$DESKTOP_PATCH_DIR/adapters/xfce.sh"
source "$DESKTOP_PATCH_DIR/adapters/mate.sh"
source "$DESKTOP_PATCH_DIR/adapters/budgie.sh"
source "$DESKTOP_PATCH_DIR/adapters/lxqt.sh"

info "Test: All adapter functions exist"
all_funcs=true
for desktop in kde gnome cinnamon xfce mate budgie lxqt; do
    for op in detect inspect plan apply verify restore status; do
        func="${desktop}_${op}"
        if ! type "$func" &>/dev/null; then
            all_funcs=false
            fail "Missing function: $func"
        fi
    done
done
if $all_funcs; then
    pass "All adapter functions exist"
fi

# ---------------------------------------------------------------------------
# Test: Backend functions exist
# ---------------------------------------------------------------------------
header "Backend Function Tests"

# Source all backends explicitly
source "$DESKTOP_PATCH_DIR/backends/gsettings.sh"
source "$DESKTOP_PATCH_DIR/backends/xfconf.sh"

info "Test: KConfig backend functions exist"
all_funcs=true
for func in find_plasma_config find_clock_applets read_kconfig_value write_kconfig_value is_plasma_running get_plasma_version; do
    if ! type "$func" &>/dev/null; then
        all_funcs=false
        fail "Missing KConfig function: $func"
    fi
done
if $all_funcs; then
    pass "All KConfig backend functions exist"
fi

info "Test: GSettings backend functions exist"
all_funcs=true
for func in check_gsettings_available gsettings_schema_exists gsettings_key_exists read_gsettings_value write_gsettings_value; do
    if ! type "$func" &>/dev/null; then
        all_funcs=false
        fail "Missing GSettings function: $func"
    fi
done
if $all_funcs; then
    pass "All GSettings backend functions exist"
fi

info "Test: Xfconf backend functions exist"
all_funcs=true
for func in check_xfconf_available xfconf_channel_exists xfconf_property_exists read_xfconf_value write_xfconf_value find_xfce_clock_plugins; do
    if ! type "$func" &>/dev/null; then
        all_funcs=false
        fail "Missing Xfconf function: $func"
    fi
done
if $all_funcs; then
    pass "All Xfconf backend functions exist"
fi

info "Test: LXQt backend functions exist"
all_funcs=true
for func in find_lxqt_panel_config find_lxqt_clock_widgets read_lxqt_value write_lxqt_value is_lxqt_running; do
    if ! type "$func" &>/dev/null; then
        all_funcs=false
        fail "Missing LXQt function: $func"
    fi
done
if $all_funcs; then
    pass "All LXQt backend functions exist"
fi

# ---------------------------------------------------------------------------
# Test: KDE adapter inspect
# ---------------------------------------------------------------------------
header "KDE Adapter Integration Tests"

info "Test: KDE inspect with fixture"
# Set HOME to fixture dir for the test
old_home="$HOME"
export HOME="$fixture_dir"
output=$(kde_inspect 2>&1) || true
export HOME="$old_home"
if echo "$output" | grep -q "digitalclock applets"; then
    pass "KDE inspect shows digitalclock applets"
else
    fail "KDE inspect does not show digitalclock applets"
fi

# ---------------------------------------------------------------------------
# Test: Manifest JSON safety
# ---------------------------------------------------------------------------
header "Manifest JSON Safety Tests"

info "Test: Manifest handles special characters in values"
manifest_special="${SANDBOX_ROOT}/state/manifest-special.json"
init_manifest "$state_dir" "kde" "5.27" "wayland" "America/Vancouver" "kconfig" > /dev/null
# Get the actual manifest file that was created
manifest_special=$(ls -t "$state_dir"/manifest-*.json 2>/dev/null | head -1)
if [[ -z "$manifest_special" ]]; then
    fail "Could not find manifest file"
else
    # Value with quotes and special chars
    add_manifest_change "$manifest_special" "file" "/path/to/file" 'value with "quotes"' 'new value' "" 2>/dev/null
    if python3 -c "import json; json.load(open('$manifest_special'))" 2>/dev/null; then
        pass "Manifest handles special characters"
    else
        fail "Manifest fails with special characters"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
header "Test Summary"
echo ""
echo "Total:  $TOTAL_TESTS"
echo -e "Passed: ${GREEN}${PASSED_TESTS}${NC}"
echo -e "Failed: ${RED}${FAILED_TESTS}${NC}"
echo ""

if [[ "$FAILED_TESTS" -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
