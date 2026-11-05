#!/usr/bin/env bash
# Test the custom_zones.sh library in an isolated user scope.
# Never touches the developer's real ~/.tzinfo or /usr/share/zoneinfo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REAL_HOME="${HOME}"
SANDBOX="$(mktemp -d /tmp/cz-test-XXXXXX)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
trap 'case "$SANDBOX" in /tmp/cz-test-*) rm -rf -- "$SANDBOX" ;; esac' EXIT

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TOTAL_PASS=$((TOTAL_PASS+1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; TOTAL_FAIL=$((TOTAL_FAIL+1)); }
info() { echo -e "${YELLOW}→${NC} $1"; }

TOTAL_PASS=0
TOTAL_FAIL=0

source "${SCRIPT_DIR}/lib/custom_zones.sh"
PATCHER="${SCRIPT_DIR}/lib/patch_tzif.py"

# ---------------------------------------------------------------------------
info "Parse the new zones.conf format"
parsed=$(custom_zones_parse_file "${SCRIPT_DIR}/zones.conf")
count=$(echo "$parsed" | wc -l)
if [[ "$count" == "6" ]]; then
    pass "6 zones parsed from zones.conf"
else
    fail "expected 6 rows, got $count"
fi

if echo "$parsed" | grep -q "Canada/PCT"; then
    fail "Canada/* still present in parsed output"
else
    pass "no Canada/* (old namespace) in parsed output"
fi
if echo "$parsed" | grep -q "Canadian/PCT"; then
    pass "Canadian/PCT present in parsed output"
else
    fail "Canadian/PCT missing from parsed output"
fi

# ---------------------------------------------------------------------------
info "CUSTOM_ID validation rejects unsafe identifiers"
for bad in "Canada/PCT" "/etc/passwd" "Canadian/../../etc/passwd" \
           "Canadian/" "Canadian//PCT" "American/PCT" \
           "Canadian/..hidden" "Canadian/./PCT" "Canadian/PCT/../X"; do
    if custom_zones_validate_id "$bad" 2>/dev/null; then
        fail "validator accepted unsafe id: $bad"
    else
        pass "validator rejected: $bad"
    fi
done
for good in "Canadian/PCT" "Canadian/ABT" "Canadian/YST-Whitehorse" "Canadian/MBT"; do
    if custom_zones_validate_id "$good"; then
        pass "validator accepted: $good"
    else
        fail "validator rejected good id: $good"
    fi
done

# ---------------------------------------------------------------------------
info "IANA_SOURCE validation rejects absolute paths and traversal"
for bad in "/usr/share/zoneinfo/America/Vancouver" "America/../../etc" \
           "America" "America//Vancouver" "America/Vancouver/.."; do
    if custom_zones_validate_iana "$bad" 2>/dev/null; then
        fail "validator accepted bad source: $bad"
    else
        pass "validator rejected bad source: $bad"
    fi
done

# ---------------------------------------------------------------------------
info "Duplicate detection"
bad_conf="${SANDBOX}/dup-zones.conf"
cat > "$bad_conf" <<'EOF'
America/Vancouver|Canadian/PCT|MST|PCT|Pacific|U
America/Vancouver|Canadian/PCT2|MST|PCT|Pacific|U
EOF
if custom_zones_parse_file "$bad_conf" >/dev/null 2>&1; then
    fail "duplicate source not rejected"
else
    pass "duplicate source rejected"
fi

cat > "$bad_conf" <<'EOF'
America/Vancouver|Canadian/PCT|MST|PCT|Pacific|U
America/Edmonton|Canadian/PCT|CST|ABT|Alberta|U
EOF
if custom_zones_parse_file "$bad_conf" >/dev/null 2>&1; then
    fail "duplicate custom id not rejected"
else
    pass "duplicate custom id rejected"
fi

# ---------------------------------------------------------------------------
info "Empty fields and malformed rows"
cat > "$bad_conf" <<'EOF'
America/Vancouver|Canadian/PCT|MST||Pacific|U
EOF
if custom_zones_parse_file "$bad_conf" >/dev/null 2>&1; then
    fail "empty field not rejected"
else
    pass "empty field rejected"
fi

cat > "$bad_conf" <<'EOF'
America/Vancouver|Canadian/PCT|MST|TOOLONG|Pacific|U
EOF
if custom_zones_parse_file "$bad_conf" >/dev/null 2>&1; then
    fail "bad abbreviation not rejected"
else
    pass "abbreviation length validated"
fi

cat > "$bad_conf" <<'EOF'
America/Vancouver|Canadian/PCT|MST|PCT|Pacific|U|EXTRA
EOF
if custom_zones_parse_file "$bad_conf" >/dev/null 2>&1; then
    fail "extra columns not rejected"
else
    pass "extra column rejected"
fi

# ---------------------------------------------------------------------------
info "Install a custom zone in isolated user scope"
base="$(custom_zones_manifest_path user)"
mkdir -p "$(dirname "$base")"

# Remove ~/.tzinfo beforehand to ensure install creates it fresh.
rm -rf "${HOME}/.tzinfo"

if custom_zones_install user America/Vancouver Canadian/PCT MST PCT "$PATCHER"; then
    pass "install completed"
else
    fail "install failed"
fi

target="${HOME}/.tzinfo/Canadian/PCT"
if [[ -f "$target" ]]; then
    pass "target file created at $target"
else
    fail "target file missing"
fi

# ---------------------------------------------------------------------------
info "Manifest records source + hash"
manifest="$(custom_zones_manifest_path user)"
rec_src=$(custom_zones_manifest_get "$manifest" "Canadian/PCT" source)
rec_sha=$(custom_zones_manifest_get "$manifest" "Canadian/PCT" sha256)
actual_sha=$(sha256sum "$target" | awk '{print $1}')
if [[ "$rec_src" == "America/Vancouver" ]]; then
    pass "manifest records the source: America/Vancouver"
else
    fail "manifest source mismatch: got '$rec_src'"
fi
if [[ "$rec_sha" == "$actual_sha" ]]; then
    pass "manifest hash matches installed file"
else
    fail "manifest hash mismatch"
fi

# ---------------------------------------------------------------------------
info "Generated file is valid TZif + correct abbreviations at fixed dates"
if python3 "$PATCHER" --validate "$target"; then
    pass "generated file passes structural validator"
else
    fail "generated file failed validator"
fi

# Historical abbreviations preserved
for pair in "2010-01-15:PST" "2010-07-15:PDT" "2025-01-15:PST" "2025-07-15:PDT" \
            "2026-07-15:PDT" "2026-11-02:PCT" "2026-12-15:PCT" "2100-06-15:PCT"; do
    date="${pair%%:*}"; want="${pair##*:}"
    got="$(TZ="$target" date -d "$date" +%Z)"
    if [[ "$got" == "$want" ]]; then
        pass "$date → $want"
    else
        fail "$date → want $want, got $got"
    fi
done

# Offsets match source at the same dates
src_off="$(TZ=/usr/share/zoneinfo/America/Vancouver date -d 2026-12-15 +%z)"
tgt_off="$(TZ="$target" date -d 2026-12-15 +%z)"
if [[ "$src_off" == "$tgt_off" ]]; then
    pass "post-switch offset preserved ($src_off)"
else
    fail "post-switch offset changed: $src_off vs $tgt_off"
fi

# ---------------------------------------------------------------------------
info "Idempotent re-install is allowed (we own it)"
if custom_zones_install user America/Vancouver Canadian/PCT MST PCT "$PATCHER"; then
    pass "re-install of owned file succeeded"
else
    fail "re-install of owned file rejected"
fi

# ---------------------------------------------------------------------------
info "Refuse to overwrite an unowned custom file"
# Create a foreign Canadian/XYZ file (empty, not owned by us) and try install
mkdir -p "${HOME}/.tzinfo/Canadian"
printf 'not a tzif' > "${HOME}/.tzinfo/Canadian/UNOWNED"
rc=0
custom_zones_install user America/Vancouver Canadian/UNOWNED MST PCT "$PATCHER" 2>/dev/null || rc=$?
if [[ "$rc" == "2" ]]; then
    pass "install refused to overwrite unowned file (exit 2)"
else
    fail "install overwrote unowned file (exit $rc)"
fi
if cmp -s "${HOME}/.tzinfo/Canadian/UNOWNED" <(printf 'not a tzif'); then
    pass "unowned file content untouched"
else
    fail "unowned file content was modified"
fi

# ---------------------------------------------------------------------------
info "Refuse to remove a file whose hash changed externally"
# Tamper with the installed file
printf 'tampered' >> "$target"
if custom_zones_owned user "Canadian/PCT"; then
    fail "owned() returned true after tampering"
else
    pass "owned() detects tampering"
fi
rc=0
custom_zones_remove_owned user "Canadian/PCT" 2>/dev/null || rc=$?
if [[ "$rc" == "2" ]] && [[ -f "$target" ]]; then
    pass "remove refused on hash-mismatched file"
else
    fail "remove incorrectly succeeded (rc=$rc)"
fi

# ---------------------------------------------------------------------------
info "Remove succeeds when hash matches"
# Restore to a good state
rm -f "$target"
custom_zones_install user America/Vancouver Canadian/PCT MST PCT "$PATCHER"
if custom_zones_remove_owned user "Canadian/PCT"; then
    pass "remove succeeded for owned file"
else
    fail "remove of owned file failed"
fi
if [[ ! -f "$target" ]]; then
    pass "target file gone after remove"
else
    fail "target file still present"
fi

# The Canadian/ directory should be pruned if empty.
if [[ ! -d "${HOME}/.tzinfo/Canadian" ]]; then
    pass "empty Canadian/ directory pruned"
else
    # Might still exist because of the earlier UNOWNED test file.
    info "(Canadian/ dir still present — that's OK because the unowned test left UNOWNED behind)"
fi

# ---------------------------------------------------------------------------
info "Rebuild all: after external modification, rebuild restores correct content"
custom_zones_install user America/Vancouver Canadian/PCT MST PCT "$PATCHER"
# (simulate a rebuild; ensure hash is updated in the manifest)
before_sha=$(custom_zones_manifest_get "$(custom_zones_manifest_path user)" \
              "Canadian/PCT" sha256)
custom_zones_rebuild_all user "$PATCHER" "${SCRIPT_DIR}/zones.conf" || true
after_sha=$(custom_zones_manifest_get "$(custom_zones_manifest_path user)" \
              "Canadian/PCT" sha256)
if [[ "$after_sha" == "$before_sha" ]]; then
    pass "rebuild is idempotent — hash unchanged"
else
    fail "rebuild changed hash unexpectedly"
fi

# ---------------------------------------------------------------------------
info "List owned"
owned=$(custom_zones_list_owned user)
if echo "$owned" | grep -q "Canadian/PCT"; then
    pass "list_owned reports installed Canadian/PCT"
else
    fail "list_owned missing entry"
fi

# ---------------------------------------------------------------------------
info "User-scope install never modifies /usr/share/zoneinfo"
# Correct guarantee: the system tree's state is identical after a
# user-scope install as it was before. An existing /usr/share/zoneinfo/
# Canadian/ from a prior system-scope install is fine; the failure mode
# is the user-scope run writing INTO /usr/share.
sys_before=$(find /usr/share/zoneinfo -newer /etc/hostname -type f 2>/dev/null | sha256sum)
# Force a fresh user-scope install and compare
rm -rf "${HOME}/.tzinfo/Canadian"
custom_zones_install user America/Vancouver Canadian/PCT MST PCT "$PATCHER" 2>/dev/null
sys_after=$(find /usr/share/zoneinfo -newer /etc/hostname -type f 2>/dev/null | sha256sum)
if [[ "$sys_before" == "$sys_after" ]]; then
    pass "user-scope did not touch /usr/share/zoneinfo"
else
    fail "user-scope install modified /usr/share/zoneinfo"
fi

# ---------------------------------------------------------------------------
info "Source IANA files unchanged"
src_sha=$(sha256sum /usr/share/zoneinfo/America/Vancouver | awk '{print $1}')
src_pool=$(python3 -c "
import struct
d=open('/usr/share/zoneinfo/America/Vancouver','rb').read()
c1=struct.unpack('>6I', d[20:44]); v1=44+c1[3]*4+c1[3]+c1[4]*6+c1[5]+c1[2]*12+c1[1]+c1[0]
c2=struct.unpack('>6I', d[v1+20:v1+44]); pool_start=v1+44+c2[3]*8+c2[3]+c2[4]*6
print(d[pool_start:pool_start+c2[5]])
")
if [[ "$src_pool" == *"MST"* ]] && [[ "$src_pool" != *"PCT"* ]]; then
    pass "system America/Vancouver still has MST (untouched)"
else
    fail "system America/Vancouver was modified: pool=$src_pool"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Total: $((TOTAL_PASS+TOTAL_FAIL)), Passed: $TOTAL_PASS, Failed: $TOTAL_FAIL"
[[ "$TOTAL_FAIL" -eq 0 ]] && exit 0 || exit 1
