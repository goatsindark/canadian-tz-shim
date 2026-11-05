#!/usr/bin/env bash
# Canadian Timezone Shim - Comprehensive Test Suite
# Tests installation lifecycle, safety, and correctness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zones.conf"

# Isolated sandbox for user-mode runs so no test can touch the real home directory
REAL_HOME="${HOME}"
SANDBOX_ROOT="$(mktemp -d "/tmp/tzshim-sandbox-XXXXXX")"

# Test mode: user or system
if [[ "${1:-}" == "--system" ]] || [[ $EUID -eq 0 ]]; then
    TEST_MODE="system"
    ZONEINFO_DIR="/usr/local/share/zoneinfo"
    STATE_DIR="/var/lib/canadian-tz-shim"
    CONFIG_PATH="/etc/tzshim.conf"
else
    TEST_MODE="user"
    # Redirect HOME into the sandbox; ZONEINFO_DIR/STATE_DIR/CONFIG_PATH derive from it
    export HOME="${SANDBOX_ROOT}/home"
    mkdir -p "$HOME"
    ZONEINFO_DIR="${HOME}/.tzinfo"
    STATE_DIR="${HOME}/.local/state/canadian-tz-shim"
    CONFIG_PATH="${HOME}/.config/tzshim.conf"
fi

sandbox_cleanup() {
    case "$SANDBOX_ROOT" in
        /tmp/tzshim-sandbox-*) rm -rf -- "$SANDBOX_ROOT" ;;
        *) echo "REFUSING to remove unexpected sandbox path: $SANDBOX_ROOT" >&2 ;;
    esac
}
trap sandbox_cleanup EXIT

# Hard guard: in user mode we must never operate on the developer's real home
if [[ "$TEST_MODE" == "user" ]]; then
    case "$HOME" in
        "$REAL_HOME")
            echo "FATAL: user-mode tests must not run against the real HOME ($REAL_HOME)" >&2
            exit 1
            ;;
    esac
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✓ PASS${NC} $*"
}

fail() {
    echo -e "${RED}✗ FAIL${NC} $*"
    exit 1
}

info() {
    echo -e "${YELLOW}[TEST]${NC} $*"
}

header() {
    echo -e "${BLUE}$*${NC}"
}

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Configuration file not found: $CONFIG_FILE"
fi

header "Canadian Timezone Shim Test Suite ($TEST_MODE mode)"
echo ""

total_tests=0
passed_tests=0

# Bootstrap: establish a known-good installation to test against.
# In user mode this installs into the sandbox HOME, never the real home.
header "Bootstrap: installing into ${TEST_MODE} target"
if [[ "$TEST_MODE" == "user" ]]; then
    # Non-interactive user-level install
    if ! bash "${SCRIPT_DIR}/install.sh" >/dev/null 2>&1; then
        fail "Bootstrap install.sh failed in sandbox HOME=$HOME"
    fi
    # The new architecture installs custom Canadian/* zones under ~/.tzinfo/.
    if [[ ! -f "$ZONEINFO_DIR/Canadian/PCT" ]]; then
        fail "Bootstrap did not create custom Canadian/PCT in $ZONEINFO_DIR"
    fi
    pass "Installed custom zones into sandbox: $ZONEINFO_DIR/Canadian/"
else
    info "System mode: expects an existing system-wide installation"
    if [[ ! -f "$ZONEINFO_DIR/Canadian/PCT" ]]; then
        fail "No system-wide installation found at $ZONEINFO_DIR/Canadian/PCT (run: sudo ./install.sh)"
    fi
fi
echo ""

# Test 1: Verify installation
header "Test Group 1: Installation Verification"
info "Test: Custom Canadian/* timezone files exist for every zones.conf row"
all_exist=true
while IFS='|' read -r iana_zone custom_id iana_abbrev official_abbrev official_name reference_url; do
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue

    target="${ZONEINFO_DIR}/${custom_id}"
    if [[ ! -f "$target" ]]; then
        fail "Custom timezone not found: $target"
        fail "Please run ./install.sh first."
    fi
done < "$CONFIG_FILE"
total_tests=$((total_tests + 1))
passed_tests=$((passed_tests + 1))
pass "All custom Canadian/* timezone files exist"
echo ""

# Test 1b: Official IANA source files under /usr/share/zoneinfo remain untouched
header "Test Group 1b: IANA sources unchanged"
info "Test: /usr/share/zoneinfo/America/Vancouver still uses MST pool"
if [[ -f /usr/share/zoneinfo/America/Vancouver ]]; then
    pool_after=$(python3 -c "
import struct
d=open('/usr/share/zoneinfo/America/Vancouver','rb').read()
c1=struct.unpack('>6I', d[20:44]); v1=44+c1[3]*4+c1[3]+c1[4]*6+c1[5]+c1[2]*12+c1[1]+c1[0]
c2=struct.unpack('>6I', d[v1+20:v1+44])
p=v1+44+c2[3]*8+c2[3]+c2[4]*6
import sys; sys.stdout.write(d[p:p+c2[5]].decode('latin-1'))
")
    if [[ "$pool_after" == *"MST"* ]] && [[ "$pool_after" != *"PCT"* ]]; then
        pass "America/Vancouver source untouched (still MST-only pool)"
    else
        fail "America/Vancouver source was modified! pool=$pool_after"
    fi
    total_tests=$((total_tests + 1)); passed_tests=$((passed_tests + 1))
fi
echo ""

# Test 2: Verify state files
header "Test Group 2: State File Verification"
if [[ "$TEST_MODE" == "system" ]]; then
    info "Test: System state files exist"
    if [[ -f "${STATE_DIR}/selected-zone" ]]; then
        total_tests=$((total_tests + 1))
        passed_tests=$((passed_tests + 1))
        pass "Selected zone state file exists"
    else
        fail "Selected zone state file not found: ${STATE_DIR}/selected-zone"
    fi

    info "Test: Config file exists"
    if [[ -f "$CONFIG_PATH" ]]; then
        total_tests=$((total_tests + 1))
        passed_tests=$((passed_tests + 1))
        pass "Config file exists at $CONFIG_PATH"
    else
        fail "Config file not found: $CONFIG_PATH"
    fi
else
    info "Test: User config file exists"
    if [[ -f "$CONFIG_PATH" ]]; then
        total_tests=$((total_tests + 1))
        passed_tests=$((passed_tests + 1))
        pass "User config file exists at $CONFIG_PATH"
    else
        fail "User config file not found: $CONFIG_PATH"
    fi
fi
echo ""

# Test 3: Verify timezone abbreviations for all zones
header "Test Group 3: Timezone Abbreviation Tests"
while IFS='|' read -r iana_zone custom_id iana_abbrev official_abbrev official_name reference_url; do
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue

    patched_zone="${ZONEINFO_DIR}/${custom_id}"

    header "Testing: ${custom_id} (source: $iana_zone, $official_name)"

    # Test: Date after transition should show official abbreviation
    total_tests=$((total_tests + 1))
    info "Test: Date after transition should show $official_abbrev"

    # Determine transition date
    if [[ "$iana_zone" == "America/Whitehorse" || "$iana_zone" == "America/Dawson" ]]; then
        transition_date="2020-11-01"
        pre_transition_date="2019-01-15"
        pre_transition_summer="2019-07-15"
    else
        transition_date="2026-11-01"
        pre_transition_date="2025-01-15"
        pre_transition_summer="2025-07-15"
    fi

    result=$(TZ="$patched_zone" date -d "$transition_date 12:00:00" +"%Z")
    if [[ "$result" == "$official_abbrev" ]]; then
        pass "$transition_date shows $official_abbrev"
        passed_tests=$((passed_tests + 1))
    else
        fail "$transition_date shows $result (expected $official_abbrev)"
    fi

    # Test: Date before transition (winter) should show old standard abbreviation
    total_tests=$((total_tests + 1))
    info "Test: Date before transition (winter) should show old standard abbreviation"
    result=$(TZ="$patched_zone" date -d "$pre_transition_date" +"%Z")

    # Determine expected old abbreviation
    case "$iana_zone" in
        America/Vancouver) expected_old="PST" ;;
        America/Edmonton) expected_old="MST" ;;
        America/Yellowknife) expected_old="MST" ;;
        America/Winnipeg) expected_old="CST" ;;
        America/Whitehorse|America/Dawson) expected_old="PST" ;;
    esac

    if [[ "$result" == "$expected_old" ]]; then
        pass "$pre_transition_date shows $result (pre-transition standard time)"
        passed_tests=$((passed_tests + 1))
    else
        fail "$pre_transition_date shows $result (expected $expected_old)"
    fi

    # Test: Date before transition (summer) should show old daylight abbreviation
    total_tests=$((total_tests + 1))
    info "Test: Date before transition (summer) should show old daylight abbreviation"
    result=$(TZ="$patched_zone" date -d "$pre_transition_summer" +"%Z")

    # Determine expected old daylight abbreviation
    case "$iana_zone" in
        America/Vancouver) expected_old_daylight="PDT" ;;
        America/Edmonton) expected_old_daylight="MDT" ;;
        America/Yellowknife) expected_old_daylight="MDT" ;;
        America/Winnipeg) expected_old_daylight="CDT" ;;
        America/Whitehorse|America/Dawson) expected_old_daylight="PDT" ;;
    esac

    if [[ "$result" == "$expected_old_daylight" ]]; then
        pass "$pre_transition_summer shows $result (pre-transition daylight time)"
        passed_tests=$((passed_tests + 1))
    else
        fail "$pre_transition_summer shows $result (expected $expected_old_daylight)"
    fi

    # Test: UTC offset should be correct
    total_tests=$((total_tests + 1))
    info "Test: UTC offset should be correct for $official_abbrev"
    result=$(TZ="$patched_zone" date -d "$transition_date 12:00:00" +"%z")

    case "$official_abbrev" in
        PCT) expected_offset="-0700" ;;
        ABT) expected_offset="-0600" ;;
        YST) expected_offset="-0700" ;;
        MBT) expected_offset="-0500" ;;
        NWT) expected_offset="-0600" ;;
    esac

    if [[ "$result" == "$expected_offset" ]]; then
        pass "$transition_date offset is $result"
        passed_tests=$((passed_tests + 1))
    else
        fail "$transition_date offset is $result (expected $expected_offset)"
    fi

    # Test: Future date (year 2100) should show official abbreviation
    total_tests=$((total_tests + 1))
    info "Test: Future date (2100) should show $official_abbrev"
    result=$(TZ="$patched_zone" date -d "2100-06-15 12:00:00" +"%Z")
    if [[ "$result" == "$official_abbrev" ]]; then
        pass "2100-06-15 shows $official_abbrev"
        passed_tests=$((passed_tests + 1))
    else
        fail "2100-06-15 shows $result (expected $official_abbrev)"
    fi

    # Test: Exact transition boundary
    total_tests=$((total_tests + 1))
    info "Test: Exact transition boundary"
    if [[ "$iana_zone" == "America/Whitehorse" || "$iana_zone" == "America/Dawson" ]]; then
        before_transition=$(TZ="$patched_zone" date -d "2020-10-31 23:59:59" +"%Z")
        after_transition=$(TZ="$patched_zone" date -d "2020-11-01 00:00:00" +"%Z")
        if [[ "$before_transition" == "PDT" && "$after_transition" == "$official_abbrev" ]]; then
            pass "Transition boundary correct"
            passed_tests=$((passed_tests + 1))
        else
            fail "Transition boundary incorrect: before=$before_transition, after=$after_transition"
        fi
    else
        before_transition=$(TZ="$patched_zone" date -d "2026-11-01 01:59:59" +"%Z")
        after_transition=$(TZ="$patched_zone" date -d "2026-11-01 02:00:00" +"%Z")
        if [[ "$before_transition" == "PDT" || "$before_transition" == "MDT" || "$before_transition" == "CDT" ]]; then
            if [[ "$after_transition" == "$official_abbrev" ]]; then
                pass "Transition boundary correct"
                passed_tests=$((passed_tests + 1))
            else
                fail "Transition boundary incorrect: before=$before_transition, after=$after_transition"
            fi
        else
            fail "Unexpected pre-transition abbreviation: $before_transition"
        fi
    fi

    echo ""
done < "$CONFIG_FILE"

# Test 4: Reapplication test (system mode only)
if [[ "$TEST_MODE" == "system" ]]; then
    header "Test Group 4: Reapplication Test"
    if [[ -x "${SCRIPT_DIR}/lib/reapply.sh" ]]; then
        info "Test: Reapply script exists and is executable"
        total_tests=$((total_tests + 1))
        passed_tests=$((passed_tests + 1))
        pass "Reapply script exists and is executable"

        info "Test: Running reapply script"
        if sudo "${SCRIPT_DIR}/lib/reapply.sh" 2>&1 | grep -q "Re-patched"; then
            total_tests=$((total_tests + 1))
            passed_tests=$((passed_tests + 1))
            pass "Reapply script executed successfully"
        else
            total_tests=$((total_tests + 1))
            fail "Reapply script did not produce expected output"
        fi
    else
        info "Test: Reapply script not found or not executable (skipped)"
    fi
    echo ""
fi

# Test 5: Idempotency test
header "Test Group 5: Idempotency Test"
info "Test: Re-running install.sh does not alter the installed custom zones"
# Snapshot the hash of one installed custom file
sample_custom="Canadian/PCT"
sample_path="${ZONEINFO_DIR}/${sample_custom}"
hash_before=$(sha256sum "$sample_path" | awk '{print $1}')

output=$(bash "${SCRIPT_DIR}/install.sh" 2>&1 || true)

hash_after=$(sha256sum "$sample_path" | awk '{print $1}')
total_tests=$((total_tests + 1))
if [[ "$hash_before" == "$hash_after" ]]; then
    passed_tests=$((passed_tests + 1))
    pass "Install idempotent — custom zone file unchanged"
else
    fail "Install changed ${sample_custom}: $hash_before → $hash_after"
fi

# Also: manifest hash must still match the file (ownership preserved)
total_tests=$((total_tests + 1))
manifest_path=$( [ "$TEST_MODE" == "user" ] \
                  && echo "$HOME/.local/state/canadian-tz-shim/custom-zones.json" \
                  || echo "/var/lib/canadian-tz-shim/custom-zones.json" )
recorded=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d['zones']['${sample_custom}']['sha256'])
" "$manifest_path")
if [[ "$recorded" == "$hash_after" ]]; then
    passed_tests=$((passed_tests + 1))
    pass "Manifest hash updated and matches installed file"
else
    fail "Manifest hash drift: recorded=$recorded actual=$hash_after"
fi
echo ""

# Test 6: Config file preservation test
header "Test Group 6: Config File Integrity"
total_tests=$((total_tests + 1))
if [[ -f "$CONFIG_PATH" ]]; then
    if grep -q "^installed_version=" "$CONFIG_PATH"; then
        passed_tests=$((passed_tests + 1))
        pass "Config records installed_version"
    else
        fail "Config does not record installed_version"
    fi
else
    fail "Config file not found at $CONFIG_PATH"
fi

# Regression: metadata must never point restoration back into a shim directory
total_tests=$((total_tests + 1))
if grep -Eq '^(original_timezone|original_timezone_path)=.*/(usr/local/share/zoneinfo|\.tzinfo)/' "$CONFIG_PATH" 2>/dev/null; then
    fail "Self-referential restoration metadata present (would break uninstall)"
else
    passed_tests=$((passed_tests + 1))
    pass "Restoration metadata is not self-referential"
fi
echo ""

# Test 7: Reinstallation preserves original timezone metadata
header "Test Group 7: Reinstallation Metadata Preservation"
if [[ -f "$CONFIG_PATH" ]]; then
    original_value=$( { grep '^original_timezone' "$CONFIG_PATH" || true; } | sort )

    info "Test: Reinstalling should preserve original timezone metadata"
    bash "${SCRIPT_DIR}/install.sh" >/dev/null 2>&1 || true

    if [[ -f "$CONFIG_PATH" ]]; then
        new_value=$( { grep '^original_timezone' "$CONFIG_PATH" || true; } | sort )
        if [[ "$original_value" == "$new_value" ]]; then
            total_tests=$((total_tests + 1))
            passed_tests=$((passed_tests + 1))
            if [[ -z "$original_value" ]]; then
                pass "Absent restoration metadata not fabricated on reinstall"
            else
                pass "Original timezone metadata preserved across reinstallation"
            fi
        else
            total_tests=$((total_tests + 1))
            fail "Original timezone metadata changed: [$original_value] → [$new_value]"
        fi
    else
        total_tests=$((total_tests + 1))
        fail "Config file disappeared after reinstallation"
    fi
else
    total_tests=$((total_tests + 1))
    fail "Config file not found for reinstallation test"
fi
echo ""

# Summary
header "Test Summary"
echo ""
echo "  Total tests: $total_tests"
echo "  Passed: $passed_tests"
echo "  Failed: $((total_tests - passed_tests))"
echo ""

if [[ $passed_tests -eq $total_tests ]]; then
    info "All tests passed! ✓"
    echo ""
    echo "All Canadian timezone patches are working correctly."
    echo "Historical timezone transitions are preserved."
    echo "Future dates work correctly."
    echo "Installation lifecycle is safe and idempotent."
    if [[ "$TEST_MODE" == "system" ]]; then
        echo "Reapplication and metadata preservation work correctly."
    fi
    exit 0
else
    fail "Some tests failed. Please review the output above."
fi
