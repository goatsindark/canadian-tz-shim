#!/usr/bin/env bash
# Canadian Timezone Shim - Test script
# Verifies all patched timezones work correctly

set -euo pipefail

ZONEINFO_DIR="${HOME}/.zoneinfo"
CONFIG_FILE="$(dirname "${BASH_SOURCE[0]}")/zones.conf"

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

header "Canadian Timezone Shim Test Suite"
echo ""

total_tests=0
passed_tests=0

# Read configuration and test each zone
while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
    # Skip comments and empty lines
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue
    
    patched_zone="${ZONEINFO_DIR}/${iana_zone}"
    
    header "Testing: $iana_zone ($official_name)"
    
    # Check if patched timezone exists
    if [[ ! -f "$patched_zone" ]]; then
        fail "Patched timezone not found: $patched_zone"
        fail "Please run ./install.sh first."
    fi
    
    # Test 1: Date after November 1, 2026 should show official abbreviation
    total_tests=$((total_tests + 1))
    info "Test $total_tests: Date after Nov 1, 2026 should show $official_abbrev"
    result=$(TZ="$patched_zone" date -d "2026-12-15" +"%Z")
    if [[ "$result" == "$official_abbrev" ]]; then
        pass "2026-12-15 shows $official_abbrev"
        passed_tests=$((passed_tests + 1))
    else
        fail "2026-12-15 shows $result (expected $official_abbrev)"
    fi
    
    # Test 2: Date before November 1, 2026 (winter) should show standard abbreviation
    total_tests=$((total_tests + 1))
    info "Test $total_tests: Date before Nov 1, 2026 (winter) should show standard abbreviation"
    result=$(TZ="$patched_zone" date -d "2025-01-15" +"%Z")
    # For zones that changed in 2026, winter 2025 should show the old standard time
    # For Yukon (changed in 2020), winter 2019 should show old standard time
    if [[ "$iana_zone" == "America/Whitehorse" || "$iana_zone" == "America/Dawson" ]]; then
        # Yukon changed in 2020, so test 2019
        result=$(TZ="$patched_zone" date -d "2019-01-15" +"%Z")
        if [[ "$result" == "PST" ]]; then
            pass "2019-01-15 shows PST (pre-Yukon change)"
            passed_tests=$((passed_tests + 1))
        else
            fail "2019-01-15 shows $result (expected PST)"
        fi
    else
        # Other zones changed in 2026
        if [[ "$iana_zone" == "America/Vancouver" && "$result" == "PST" ]] || \
           [[ "$iana_zone" == "America/Edmonton" && "$result" == "MST" ]] || \
           [[ "$iana_zone" == "America/Yellowknife" && "$result" == "MST" ]] || \
           [[ "$iana_zone" == "America/Winnipeg" && "$result" == "CST" ]]; then
            pass "2025-01-15 shows $result (pre-change standard time)"
            passed_tests=$((passed_tests + 1))
        else
            fail "2025-01-15 shows $result (unexpected)"
        fi
    fi
    
    # Test 3: Date before November 1, 2026 (summer) should show daylight abbreviation
    total_tests=$((total_tests + 1))
    info "Test $total_tests: Date before Nov 1, 2026 (summer) should show daylight abbreviation"
    if [[ "$iana_zone" == "America/Whitehorse" || "$iana_zone" == "America/Dawson" ]]; then
        # Yukon changed in 2020, so test 2019 summer
        result=$(TZ="$patched_zone" date -d "2019-07-15" +"%Z")
        if [[ "$result" == "PDT" ]]; then
            pass "2019-07-15 shows PDT (pre-Yukon change)"
            passed_tests=$((passed_tests + 1))
        else
            fail "2019-07-15 shows $result (expected PDT)"
        fi
    else
        result=$(TZ="$patched_zone" date -d "2025-07-15" +"%Z")
        if [[ "$iana_zone" == "America/Vancouver" && "$result" == "PDT" ]] || \
           [[ "$iana_zone" == "America/Edmonton" && "$result" == "MDT" ]] || \
           [[ "$iana_zone" == "America/Yellowknife" && "$result" == "MDT" ]] || \
           [[ "$iana_zone" == "America/Winnipeg" && "$result" == "CDT" ]]; then
            pass "2025-07-15 shows $result (pre-change daylight time)"
            passed_tests=$((passed_tests + 1))
        else
            fail "2025-07-15 shows $result (unexpected)"
        fi
    fi
    
    # Test 4: Offset should be correct for official abbreviation
    total_tests=$((total_tests + 1))
    info "Test $total_tests: Offset should be correct for $official_abbrev"
    result=$(TZ="$patched_zone" date -d "2026-12-15" +"%z")
    expected_offset=""
    case "$official_abbrev" in
        PCT) expected_offset="-0700" ;;
        ABT) expected_offset="-0600" ;;
        YST) expected_offset="-0700" ;;
        MBT) expected_offset="-0500" ;;
        NWT) expected_offset="-0600" ;;
    esac
    if [[ "$result" == "$expected_offset" ]]; then
        pass "2026-12-15 offset is $result"
        passed_tests=$((passed_tests + 1))
    else
        fail "2026-12-15 offset is $result (expected $expected_offset)"
    fi
    
    # Test 5: Transition date should show official abbreviation
    total_tests=$((total_tests + 1))
    info "Test $total_tests: Transition date should show $official_abbrev"
    if [[ "$iana_zone" == "America/Whitehorse" || "$iana_zone" == "America/Dawson" ]]; then
        # Yukon transition was Nov 1, 2020
        result=$(TZ="$patched_zone" date -d "2020-11-01 12:00:00" +"%Z")
        if [[ "$result" == "$official_abbrev" ]]; then
            pass "2020-11-01 shows $official_abbrev"
            passed_tests=$((passed_tests + 1))
        else
            fail "2020-11-01 shows $result (expected $official_abbrev)"
        fi
    else
        # Other zones transitioned Nov 1, 2026
        result=$(TZ="$patched_zone" date -d "2026-11-01 12:00:00" +"%Z")
        if [[ "$result" == "$official_abbrev" ]]; then
            pass "2026-11-01 shows $official_abbrev"
            passed_tests=$((passed_tests + 1))
        else
            fail "2026-11-01 shows $result (expected $official_abbrev)"
        fi
    fi
    
    echo ""
done < "$CONFIG_FILE"

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
    exit 0
else
    fail "Some tests failed. Please review the output above."
fi
