#!/usr/bin/env bash
# Canadian Timezone Shim - Regression Tests
# Guards against previously-fixed defects from the stabilization pass

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TOTAL=0
PASSED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; TOTAL=$((TOTAL + 1)); echo "  Result: $TOTAL passed / $((TOTAL)) total"; exit 1; }
info() { echo -e "${YELLOW}→${NC} $1"; }
count() { TOTAL=$((TOTAL + 1)); }

echo "========================================"
echo "Canadian Timezone Shim - Regression Tests"
echo "========================================"
echo

# ---------------------------------------------------------------------------
# R1: Duplicate function definitions (caused by a bad replaceAll edit)
# ---------------------------------------------------------------------------
info "R1: No duplicated function definitions in shell libraries"
count
dup_found=""
for f in lib/upgrade.sh install.sh uninstall.sh lib/reapply.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] || continue
    dups=$(grep -oE '^[a-z_][a-z0-9_]*\(\) \{' "$SCRIPT_DIR/$f" | sort | uniq -d || true)
    if [[ -n "$dups" ]]; then
        dup_found+="  $f: $(echo "$dups" | tr '\n' ' ')"$'\n'
    fi
done
if [[ -z "$dup_found" ]]; then
    pass "Every function is defined exactly once"
else
    fail "Duplicate definitions found:"$'\n'"$dup_found"
fi

# ---------------------------------------------------------------------------
# R2: validate_tzif_file must be defined exactly once
# ---------------------------------------------------------------------------
info "R2: validate_tzif_file defined exactly once"
count
n=$(grep -c '^validate_tzif_file() {' "$SCRIPT_DIR/lib/upgrade.sh" || true)
if [[ "$n" -eq 1 ]]; then
    pass "validate_tzif_file has 1 definition"
else
    fail "validate_tzif_file has $n definitions (expected 1)"
fi

# ---------------------------------------------------------------------------
# R3: ANSI escape sequences must never leak into filesystem paths.
# Root cause: a setup helper wrote a colored status line to stdout, and the
# caller captured it as part of a directory path.
# ---------------------------------------------------------------------------
info "R3: No ANSI/control-character paths exist anywhere in the repository"
count
bad=$(find "$SCRIPT_DIR" -path '*/.git' -prune -o -print 2>/dev/null \
        | grep -c $'\033' || true)
if [[ "$bad" -eq 0 ]]; then
    pass "No file or directory contains ANSI escape bytes"
else
    fail "$bad path(s) contain raw ANSI escape bytes"
fi

info "R3b: No stray 'Setting up test environment' directories"
count
stray=$(find "$SCRIPT_DIR" -maxdepth 1 -name '*Setting up*' 2>/dev/null | wc -l)
if [[ "$stray" -eq 0 ]]; then
    pass "No leaked fixture directory in repository root"
else
    fail "$stray stray directory/directories present in repository root"
fi

# ---------------------------------------------------------------------------
# R4: Functions used via command substitution must emit only data to stdout
# ---------------------------------------------------------------------------
info "R4: setup_test_env emits exactly one stdout line (the path is no longer captured)"
count
if grep -q 'test_dir=$(setup_test_env)' "$SCRIPT_DIR/test-uninstall-edge-cases.sh"; then
    fail "test-uninstall-edge-cases.sh still captures setup_test_env stdout"
else
    pass "setup_test_env is no longer captured via command substitution"
fi

# ---------------------------------------------------------------------------
# R5: TZif validator must reject files that zdump wrongly accepts
# ---------------------------------------------------------------------------
info "R5: Structural validator rejects malformed TZif input"
count
T=$(mktemp -d)
printf 'corrupted data\n' > "$T/text"
: > "$T/empty"
head -c 200 /usr/share/zoneinfo/America/Vancouver > "$T/trunc" 2>/dev/null || printf 'TZifgarbage' > "$T/trunc"
printf 'TZif________________________________garbage' > "$T/fakemagic"

reject_ok=true
for case_file in text empty trunc fakemagic; do
    if python3 "$SCRIPT_DIR/lib/patch_tzif.py" --validate "$T/$case_file" >/dev/null 2>&1; then
        reject_ok=false
        echo "    validator WRONGLY ACCEPTED: $case_file"
    fi
done
if [[ "$reject_ok" == "true" ]]; then
    pass "All malformed inputs rejected (text/empty/truncated/fake-magic)"
else
    fail "Validator accepted malformed input"
fi

info "R5b: Validator still accepts a genuine TZif file"
count
if python3 "$SCRIPT_DIR/lib/patch_tzif.py" --validate /usr/share/zoneinfo/America/Vancouver >/dev/null 2>&1; then
    pass "Valid America/Vancouver accepted"
else
    fail "Valid TZif file was rejected (false positive)"
fi

info "R5c: --validate performs no writes (mtime unchanged)"
count
cp /usr/share/zoneinfo/America/Edmonton "$T/ro"
chmod 444 "$T/ro"
before_mtime=$(stat -c %Y "$T/ro")
python3 "$SCRIPT_DIR/lib/patch_tzif.py" --validate "$T/ro" >/dev/null 2>&1 || true
after_mtime=$(stat -c %Y "$T/ro")
if [[ "$before_mtime" == "$after_mtime" ]]; then
    pass "--validate is read-only"
else
    fail "--validate modified the file"
fi
rm -rf "$T"

# ---------------------------------------------------------------------------
# R6: No library function may set an EXIT trap (clobbers caller's cleanup)
# ---------------------------------------------------------------------------
info "R6: lib/upgrade.sh does not install an EXIT trap"
count
if grep -qE '^\s*trap\s+\S+\s+EXIT' "$SCRIPT_DIR/lib/upgrade.sh"; then
    fail "lib/upgrade.sh installs an EXIT trap (would clobber caller cleanup)"
else
    pass "No EXIT trap in library"
fi

# ---------------------------------------------------------------------------
# R7: Restoration metadata must not be self-referential
# ---------------------------------------------------------------------------
info "R7: install.sh rejects shim-local paths as original timezone metadata"
count
if grep -q '/usr/local/share/zoneinfo/\*)' "$SCRIPT_DIR/install.sh"; then
    pass "install.sh filters shim install dir from detected timezone"
else
    fail "install.sh lacks self-reference guard"
fi

info "R7b: uninstall.sh recovers from self-referential metadata"
count
if grep -q 'self-referential' "$SCRIPT_DIR/uninstall.sh"; then
    pass "uninstall.sh handles self-referential metadata"
else
    fail "uninstall.sh has no self-reference handling"
fi

info "R7c: uninstall.sh refuses to delete files /etc/localtime depends on"
count
if grep -q 'Refusing to delete timezone files' "$SCRIPT_DIR/uninstall.sh"; then
    pass "Pre-dependency deletion guard present"
else
    fail "Missing pre-deletion dependency guard"
fi

# ---------------------------------------------------------------------------
# R8: Health model must not conflate missing restoration metadata with a
#     broken installation (user-mode installs never touch /etc/localtime, and
#     self-referential metadata is deliberately not recorded).
#     Regression: repair previously rolled back onto the corrupt file forever.
# ---------------------------------------------------------------------------
info "R8: user-mode install without restoration metadata is considered healthy"
count
T=$(mktemp -d)
mkdir -p "$T/home/.tzinfo/America" "$T/home/.local/state/canadian-tz-shim"
for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
    cp "/usr/share/zoneinfo/America/$zone" "$T/home/.tzinfo/America/" 2>/dev/null || true
    python3 "$SCRIPT_DIR/lib/patch_tzif.py" "$T/home/.tzinfo/America/$zone" \
        "$(awk -F'|' -v z="America/$zone" '$1==z{print $2}' "$SCRIPT_DIR/zones.conf")" \
        "$(awk -F'|' -v z="America/$zone" '$1==z{print $3}' "$SCRIPT_DIR/zones.conf")" >/dev/null 2>&1 || true
done
# version metadata present, but NO original_timezone / original_timezone_path
printf 'installed_version=1.0.0\nschema_version=1\n' > "$T/home/.config_placeholder"
mkdir -p "$T/home/.config"
cp "$T/home/.config_placeholder" "$T/home/.config/tzshim.conf"

health=$(HOME="$T/home" SCRIPT_DIR="$SCRIPT_DIR" bash -c "
source '$SCRIPT_DIR/lib/upgrade.sh'
discover_installation false \"\$HOME/.tzinfo\" \"\$HOME/.local/state/canadian-tz-shim\" \"\$HOME/.config/tzshim.conf\"
echo \$INSTALLATION_HEALTHY" 2>/dev/null)
if [[ "$health" == "true" ]]; then
    pass "Healthy without restoration metadata in user mode"
else
    fail "User-mode install wrongly reported unhealthy without metadata"
fi
rm -rf "$T"

info "R8b: system mode still REQUIRES restoration metadata (uninstall safety)"
count
T=$(mktemp -d)
mkdir -p "$T/z/America" "$T/state"
for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
    cp "/usr/share/zoneinfo/America/$zone" "$T/z/America/" 2>/dev/null || true
done
printf 'installed_version=1.0.0\nschema_version=1\n' > "$T/tzshim.conf"
health=$(SCRIPT_DIR="$SCRIPT_DIR" bash -c "
source '$SCRIPT_DIR/lib/upgrade.sh'
discover_installation true '$T/z' '$T/state' '$T/tzshim.conf'
echo \$INSTALLATION_HEALTHY" 2>/dev/null)
if [[ "$health" == "false" ]]; then
    pass "System mode without metadata correctly reported unhealthy"
else
    fail "System mode reported healthy without restoration metadata"
fi
rm -rf "$T"

# ---------------------------------------------------------------------------
# R9: Corrupted and missing files must still be detected as unhealthy
# ---------------------------------------------------------------------------
info "R9: genuine file defects are still detected"
count
T=$(mktemp -d)
mkdir -p "$T/home/.tzinfo/America" "$T/state"
cp /usr/share/zoneinfo/America/Vancouver "$T/home/.tzinfo/America/"
printf 'corrupted data\n' > "$T/home/.tzinfo/America/Vancouver"
printf 'installed_version=1.0.0\nschema_version=1\n' > "$T/tzshim.conf"
res=$(SCRIPT_DIR="$SCRIPT_DIR" bash -c "
source '$SCRIPT_DIR/lib/upgrade.sh'
discover_installation false '$T/home/.tzinfo' '$T/state' '$T/tzshim.conf'
determine_upgrade_action 1.0.0 '$SCRIPT_DIR/migrations.json'
echo \"\$INSTALLATION_HEALTHY \$UPGRADE_STATE\"" 2>/dev/null)
if [[ "$res" == "false repair_required" ]]; then
    pass "Corrupt file => unhealthy, state=repair_required"
else
    fail "Unexpected result for corrupt file: [$res]"
fi
rm -rf "$T"

# ---------------------------------------------------------------------------
# R10: `[[ … ]] && continue` inside a function returns non-zero when the test
#      fails, which aborts the function under `set -e`. This previously left
#      MANAGED_FILES empty, making health checks pass vacuously and backups
#      capture nothing.
# ---------------------------------------------------------------------------
info "R10a: discover_managed_files populates all 6 zones under set -e"
count
T=$(mktemp -d)
mkdir -p "$T/z/America"
for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
    cp "/usr/share/zoneinfo/America/$zone" "$T/z/America/" 2>/dev/null || true
done
n=$(bash -c "
set -euo pipefail
SCRIPT_DIR='$SCRIPT_DIR'
source '$SCRIPT_DIR/lib/upgrade.sh'
discover_managed_files '$T/z'
echo \${#MANAGED_FILES[@]}
" 2>/dev/null)
if [[ "${n:-0}" -eq 6 ]]; then
    pass "discover_managed_files returned 6 managed files"
else
    fail "discover_managed_files returned ${n:-0} (expected 6) - loop aborted by set -e"
fi
rm -rf "$T"

info "R10b: config parsing reaches data lines under set -e"
count
# NOTE: never source install.sh here - sourcing executes a real installation.
res=$(bash -c "
set -euo pipefail
CONFIG_FILE='$SCRIPT_DIR/zones.conf'
while IFS='|' read -r iana_zone _rest; do
    if [[ \"\$iana_zone\" =~ ^#.*\$ ]]; then continue; fi
    if [[ -z \"\$iana_zone\" ]]; then continue; fi
    if [[ \"\$iana_zone\" == \"America/Edmonton\" ]]; then echo MATCH; fi
done < \"\$CONFIG_FILE\"
" 2>/dev/null)
if [[ "$res" == "MATCH" ]]; then
    pass "if-guard parsing reaches data lines correctly"
else
    fail "if-guard parsing did not reach data lines"
fi

info "R10c: no AND-OR continue/return guards remain inside function bodies"
count
offenders=$(python3 - "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" \
    "$SCRIPT_DIR/lib/upgrade.sh" "$SCRIPT_DIR/lib/reapply.sh" <<'PY'
import re, sys
for path in sys.argv[1:]:
    depth, fn = 0, None
    for line in open(path):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{', line)
        if m and depth == 0:
            fn, depth = m.group(1), line.count("{") - line.count("}")
            continue
        if fn:
            depth += line.count("{") - line.count("}")
            if not line.strip().startswith("#") and \
               re.search(r'\[\[.*\]\]\s*&&\s*(continue|return|true|:)\b', line):
                print(f"{path}:{fn}")
            if depth <= 0:
                fn, depth = None, 0
PY
)
if [[ -z "$offenders" ]]; then
    pass "No set -e-unsafe AND-OR guards inside functions"
else
    fail "Unsafe AND-OR guards remain:"$'\n'"$offenders"
fi

# ---------------------------------------------------------------------------
# R11: Upgrade backups must actually capture the managed timezone files
# ---------------------------------------------------------------------------
info "R11: create_upgrade_backup captures all 6 files with directory structure"
count
T=$(mktemp -d)
mkdir -p "$T/z/America" "$T/state"
for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
    cp "/usr/share/zoneinfo/America/$zone" "$T/z/America/" 2>/dev/null || true
done
printf 'original_timezone=America/Detroit\n' > "$T/conf"
bkinfo=$(bash -c "
set -euo pipefail
SCRIPT_DIR='$SCRIPT_DIR'
source '$SCRIPT_DIR/lib/upgrade.sh'
discover_installation false '$T/z' '$T/state' '$T/conf'
B=\$(create_upgrade_backup '$T/z' '$T/conf' '$T/state')
echo \"count=\$(find \"\$B\" -type f -path '*zoneinfo*' | wc -l)\"
echo \"has_america=\$(find \"\$B\" -type f -name 'Vancouver' -path '*America*' | wc -l)\"
rm -rf \"\$B\"
" 2>/dev/null)
if echo "$bkinfo" | grep -q "count=6" && echo "$bkinfo" | grep -q "has_america=1"; then
    pass "Backup captured 6 files preserving America/ structure"
else
    fail "Backup incomplete: $bkinfo"
fi
rm -rf "$T"

# ---------------------------------------------------------------------------
# R12: Reapplication must be transactional. A failing patcher must never
#      clobber a known-good timezone file, and must leave no .tmp residue.
#      The real lib/reapply.sh is used; only its path constants are redirected
#      into a sandbox (no root, never touches the host install).
# ---------------------------------------------------------------------------
info "R12: transactional reapply preserves good files when patching fails"
count
T=$(mktemp -d /tmp/tzshim-r12-XXXXXX)
mkdir -p "$T/libexec" "$T/confdir" "$T/zi/America" "$T/state" "$T/syszi/America"
cp "$SCRIPT_DIR/lib/patch_tzif.py" "$T/libexec/"
cp "$SCRIPT_DIR/zones.conf" "$T/confdir/"
for z in Vancouver Edmonton; do
    cp "/usr/share/zoneinfo/America/$z" "$T/syszi/America/"
    python3 "$T/libexec/patch_tzif.py" "$T/syszi/America/$z" MST PCT >/dev/null 2>&1 || true
    python3 "$T/libexec/patch_tzif.py" "$T/syszi/America/$z" CST ABT >/dev/null 2>&1 || true
    cp "$T/syszi/America/$z" "$T/zi/America/"
done
printf 'America/Vancouver\n' > "$T/state/selected-zone"

sed -e "s#^STATE_DIR=.*#STATE_DIR=\"$T/state\"#" \
    -e "s#^CONFIG_FILE=.*#CONFIG_FILE=\"$T/confdir/zones.conf\"#" \
    -e "s#^ZONEINFO_DIR=.*#ZONEINFO_DIR=\"$T/zi\"#" \
    -e "s#^PATCH_SCRIPT=.*#PATCH_SCRIPT=\"$T/libexec/patch_tzif.py\"#" \
    -e "s#/usr/share/zoneinfo#${T}/syszi#g" \
    -e "s#-L /etc/localtime#-L $T/localtime#" \
    -e "s#ln -sf \"\$target_zone\" /etc/localtime#ln -sf \"\$target_zone\" $T/localtime#" \
    "$SCRIPT_DIR/lib/reapply.sh" > "$T/reapply.sh"

before=$(md5sum "$T/zi/America/Vancouver" | cut -d' ' -f1)
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/libexec/patch_tzif.py"
chmod +x "$T/libexec/patch_tzif.py"
HOME="$T" bash "$T/reapply.sh" >/dev/null 2>&1 || true
after=$(md5sum "$T/zi/America/Vancouver" | cut -d' ' -f1)
residue=$(find "$T/zi" -name '*.tmp' | wc -l)

if [[ "$before" == "$after" && "$residue" -eq 0 ]]; then
    pass "Failed patch left good file intact and left no .tmp residue"
else
    fail "Transactional guarantee broken (clobbered=$([ "$before" != "$after" ] && echo yes || echo no), tmp_residue=$residue)"
fi
rm -rf "$T"

echo
echo "========================================"
echo "Regression Summary"
echo "========================================"
echo "Total: $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $((TOTAL - PASSED))"
echo

if [[ "$PASSED" -eq "$TOTAL" ]]; then
    echo -e "${GREEN}All regression tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some regression tests failed${NC}"
    exit 1
fi
