#!/usr/bin/env bash
# Canadian Timezone Shim - Comprehensive Test Suite
# Tests installation, functionality, reapplication, and uninstallation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zones.conf"

# Determine test mode based on arguments or environment
if [[ "${1:-}" == "--system" ]] || [[ $EUID -eq 0 ]]; then
    TEST_MODE="system"
    ZONEINFO_DIR="/usr/local/share/zoneinfo"
    STATE_DIR="/var/lib/canadian-tz-shim"
    CONFIG_PATH="/etc/tzshim.conf"
else
    TEST_MODE="user"
    ZONEINFO_DIR="${HOME}/.tzinfo"
    STATE_DIR="${HOME}/.local/state/canadian-tz-shim"
    CONFIG_PATH="${HOME}/.config/tzshim.conf"
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

# Test 1: Verify installation
header "Test Group 1: Installation Verification"
info "Test: Patched timezone files exist"
all_exist=true
while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue
    
    patched_zone="${ZONEINFO_DIR}/${iana_zone}"
    if [[ ! -f "$patched_zone" ]]; then
        fail "Patched timezone not found: $patched_zone"
        fail "Please run ./install.sh first."
    fi
done < "$CONFIG_FILE"
total_tests=$((total_tests + 1))
passed_tests=$((passed_tests + 1))
pass "All patched timezone files exist"
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
while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue
    
    patched_zone="${ZONEINFO_DIR}/${iana_zone}"
    
    header "Testing: $iana_zone ($official_name)"
    
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
info "Test: Running install.sh again should skip already-patched zones"
output=$(bash "${SCRIPT_DIR}/install.sh" 2>&1 || true)
if echo "$output" | grep -q "SKIP.*already patched"; then
    total_tests=$((total_tests + 1))
    passed_tests=$((passed_tests + 1))
    pass "Install script correctly detects already-patched zones"
else
    total_tests=$((total_tests + 1))
    fail "Install script did not detect already-patched zones"
fi
echo ""

# Test 6: Config file preservation test
header "Test Group 6: Config File Preservation Test"
info "Test: Config file contains original timezone information"
if [[ -f "$CONFIG_PATH" ]]; then
    if grep -q "original_timezone" "$CONFIG_PATH"; then
        total_tests=$((total_tests + 1))
        passed_tests=$((passed_tests + 1))
        pass "Config file contains original timezone information"
    else
        total_tests=$((total_tests + 1))
        fail "Config file does not contain original timezone information"
    fi
else
    total_tests=$((total_tests + 1))
    fail "Config file not found"
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
    if [[ "$TEST_MODE" == "system" ]]; then
        echo "Reapplication and idempotency work correctly."
    fi
    exit 0
else
    fail "Some tests failed. Please review the output above."
fi
