#!/usr/bin/env bash
# Canadian Timezone Shim - Upgrade System Test Suite
# Tests version-aware upgrades with safety guarantees

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="/tmp/canadian-tz-shim-upgrade-tests-$$"
FIXTURES_DIR="${TEST_DIR}/fixtures"
# Hermetic HOME so tests can never read or write the real user's installation
ISOLATED_HOME="${TEST_DIR}/home"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    exit 1
}

info() {
    echo -e "${YELLOW}→${NC} $1"
}

header() {
    echo -e "${BLUE}$1${NC}"
}

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0

# ============================================================================
# Test Fixtures
# ============================================================================

setup_test_environment() {
    info "Setting up test environment..."
    mkdir -p "$TEST_DIR"
    mkdir -p "$FIXTURES_DIR"
    mkdir -p "$ISOLATED_HOME/.config"
    
    # Create fixture directories
    mkdir -p "${FIXTURES_DIR}/v1.0.0_healthy"
    mkdir -p "${FIXTURES_DIR}/v0.9.0_upgradeable"
    mkdir -p "${FIXTURES_DIR}/v0.8.0_legacy"
    mkdir -p "${FIXTURES_DIR}/corrupted"
    mkdir -p "${FIXTURES_DIR}/missing_files"
    
    # Create v1.0.0 healthy installation fixture
    create_fixture_v1_healthy
    
    # Create v0.9.0 upgradeable fixture
    create_fixture_v0_9_upgradeable
    
    # Create v0.8.0 legacy fixture
    create_fixture_v0_8_legacy
    
    # Create corrupted fixture
    create_fixture_corrupted
    
    # Create missing files fixture
    create_fixture_missing_files
}

create_fixture_v1_healthy() {
    local fixture_dir="${FIXTURES_DIR}/v1.0.0_healthy"
    
    # Create config
    cat > "${fixture_dir}/tzshim.conf" <<EOF
original_timezone=America/Los_Angeles
installed_version=1.0.0
schema_version=1
EOF
    
    # Create state directory
    mkdir -p "${fixture_dir}/state"
    echo "America/Vancouver" > "${fixture_dir}/state/selected-zone"
    
    # Create timezone files (copy from system)
    mkdir -p "${fixture_dir}/zoneinfo/America"
    for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
        if [[ -f "/usr/share/zoneinfo/America/$zone" ]]; then
            cp "/usr/share/zoneinfo/America/$zone" "${fixture_dir}/zoneinfo/America/"
        fi
    done
}

create_fixture_v0_9_upgradeable() {
    local fixture_dir="${FIXTURES_DIR}/v0.9.0_upgradeable"
    
    # Create config without version info (v0.9.0 didn't have version tracking)
    cat > "${fixture_dir}/tzshim.conf" <<EOF
original_timezone=America/Los_Angeles
EOF
    
    # Create state directory
    mkdir -p "${fixture_dir}/state"
    echo "America/Vancouver" > "${fixture_dir}/state/selected-zone"
    
    # Create ALL timezone files (required for healthy installation)
    mkdir -p "${fixture_dir}/zoneinfo/America"
    for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
        if [[ -f "/usr/share/zoneinfo/America/$zone" ]]; then
            cp "/usr/share/zoneinfo/America/$zone" "${fixture_dir}/zoneinfo/America/"
        fi
    done
}

create_fixture_v0_8_legacy() {
    local fixture_dir="${FIXTURES_DIR}/v0.8.0_legacy"
    
    # Create legacy config with old field names
    cat > "${fixture_dir}/tzshim.conf" <<EOF
original_tz=America/Los_Angeles
EOF
    
    # Create state directory
    mkdir -p "${fixture_dir}/state"
    echo "America/Vancouver" > "${fixture_dir}/state/selected-zone"
    
    # Create timezone files
    mkdir -p "${fixture_dir}/zoneinfo/America"
    for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
        if [[ -f "/usr/share/zoneinfo/America/$zone" ]]; then
            cp "/usr/share/zoneinfo/America/$zone" "${fixture_dir}/zoneinfo/America/"
        fi
    done
}

create_fixture_corrupted() {
    local fixture_dir="${FIXTURES_DIR}/corrupted"
    
    # Create config
    cat > "${fixture_dir}/tzshim.conf" <<EOF
original_timezone=America/Los_Angeles
installed_version=1.0.0
schema_version=1
EOF
    
    # Create state directory
    mkdir -p "${fixture_dir}/state"
    echo "America/Vancouver" > "${fixture_dir}/state/selected-zone"
    
    # Create timezone files with one corrupted
    mkdir -p "${fixture_dir}/zoneinfo/America"
    for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
        if [[ -f "/usr/share/zoneinfo/America/$zone" ]]; then
            cp "/usr/share/zoneinfo/America/$zone" "${fixture_dir}/zoneinfo/America/"
        fi
    done
    
    # Corrupt one file
    echo "corrupted data" > "${fixture_dir}/zoneinfo/America/Vancouver"
}

create_fixture_missing_files() {
    local fixture_dir="${FIXTURES_DIR}/missing_files"
    
    # Create config
    cat > "${fixture_dir}/tzshim.conf" <<EOF
original_timezone=America/Los_Angeles
installed_version=1.0.0
schema_version=1
EOF
    
    # Create state directory
    mkdir -p "${fixture_dir}/state"
    echo "America/Vancouver" > "${fixture_dir}/state/selected-zone"
    
    # Create only some timezone files
    mkdir -p "${fixture_dir}/zoneinfo/America"
    for zone in Vancouver Edmonton; do
        if [[ -f "/usr/share/zoneinfo/America/$zone" ]]; then
            cp "/usr/share/zoneinfo/America/$zone" "${fixture_dir}/zoneinfo/America/"
        fi
    done
}

cleanup_test_environment() {
    info "Cleaning up test environment..."
    # Refuse to remove anything that is not our uniquely-suffixed test tree
    case "$TEST_DIR" in
        /tmp/canadian-tz-shim-upgrade-tests-$$) rm -rf -- "$TEST_DIR" ;;
        *) info "REFUSING to clean unexpected path: $TEST_DIR" >&2 ;;
    esac
}

# Guard: never run against non-isolated paths
case "$TEST_DIR" in
    /tmp/canadian-tz-shim-upgrade-tests-$$) ;;
    *) echo "FATAL: TEST_DIR is not an isolated path: $TEST_DIR" >&2; exit 1 ;;
esac
case "$ISOLATED_HOME" in
    /tmp/canadian-tz-shim-upgrade-tests-$$/home) ;;
    *) echo "FATAL: ISOLATED_HOME is not an isolated path: $ISOLATED_HOME" >&2; exit 1 ;;
esac

# ============================================================================
# Test Cases
# ============================================================================

test_upgrade_detection_current() {
    header "Test: Upgrade detection - current installation"
    
    local fixture_dir="${FIXTURES_DIR}/v1.0.0_healthy"
    
    # Run in subshell to isolate global state
    local result
    result=$(
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Override paths for testing
        local test_zoneinfo_dir="${fixture_dir}/zoneinfo"
        local test_state_dir="${fixture_dir}/state"
        local test_config_path="${fixture_dir}/tzshim.conf"
        
        # Discover installation
        discover_installation "false" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path"
        
        # Determine upgrade action
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Output the result
        echo "$UPGRADE_STATE"
    )
    
    # Verify state
    if [[ "$result" == "current" ]]; then
        pass "Correctly detected current installation"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Expected CURRENT state, got $result"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_upgrade_detection_upgradeable() {
    header "Test: Upgrade detection - upgradeable installation"
    
    local fixture_dir="${FIXTURES_DIR}/v0.9.0_upgradeable"
    
    # Run in subshell to isolate global state
    local result
    result=$(
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Override paths
        local test_zoneinfo_dir="${fixture_dir}/zoneinfo"
        local test_state_dir="${fixture_dir}/state"
        local test_config_path="${fixture_dir}/tzshim.conf"
        
        # Discover installation
        discover_installation "false" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path"
        
        # Determine upgrade action
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Output the result
        echo "$UPGRADE_STATE"
    )
    
    # Verify state
    if [[ "$result" == "upgrade_available" ]]; then
        pass "Correctly detected upgradeable installation"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Expected UPGRADE_AVAILABLE state, got $result"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_upgrade_detection_legacy() {
    header "Test: Upgrade detection - legacy installation"
    
    local fixture_dir="${FIXTURES_DIR}/v0.8.0_legacy"
    
    # Run in subshell to isolate global state
    local result
    result=$(
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Override paths
        local test_zoneinfo_dir="${fixture_dir}/zoneinfo"
        local test_state_dir="${fixture_dir}/state"
        local test_config_path="${fixture_dir}/tzshim.conf"
        
        # Discover installation
        discover_installation "false" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path"
        
        # Determine upgrade action
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Output the result
        echo "$UPGRADE_STATE"
    )
    
    # Verify state
    if [[ "$result" == "upgrade_available" ]]; then
        pass "Correctly detected legacy installation"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Expected UPGRADE_AVAILABLE state, got $result"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_upgrade_detection_corrupted() {
    header "Test: Upgrade detection - corrupted installation"
    
    local fixture_dir="${FIXTURES_DIR}/corrupted"
    
    # Run in subshell to isolate global state
    local result
    result=$(
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Override paths
        local test_zoneinfo_dir="${fixture_dir}/zoneinfo"
        local test_state_dir="${fixture_dir}/state"
        local test_config_path="${fixture_dir}/tzshim.conf"
        
        # Discover installation
        discover_installation "false" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path"
        
        # Determine upgrade action
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Output the result
        echo "$UPGRADE_STATE"
    )
    
    # Verify state
    if [[ "$result" == "repair_required" ]]; then
        pass "Correctly detected corrupted installation"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Expected REPAIR_REQUIRED state, got $result"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_upgrade_detection_missing_files() {
    header "Test: Upgrade detection - missing files"
    
    local fixture_dir="${FIXTURES_DIR}/missing_files"
    
    # Run in subshell to isolate global state
    local result
    result=$(
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Override paths
        local test_zoneinfo_dir="${fixture_dir}/zoneinfo"
        local test_state_dir="${fixture_dir}/state"
        local test_config_path="${fixture_dir}/tzshim.conf"
        
        # Discover installation
        discover_installation "false" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path"
        
        # Determine upgrade action
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Output the result
        echo "$UPGRADE_STATE"
    )
    
    # Verify state
    if [[ "$result" == "repair_required" ]]; then
        pass "Correctly detected missing files"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Expected REPAIR_REQUIRED state, got $result"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_upgrade_detection_not_installed() {
    header "Test: Upgrade detection - not installed"
    
    # Run in subshell to isolate global state
    local result
    result=$(
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Use non-existent paths
        local test_zoneinfo_dir="${TEST_DIR}/nonexistent/zoneinfo"
        local test_state_dir="${TEST_DIR}/nonexistent/state"
        local test_config_path="${TEST_DIR}/nonexistent/tzshim.conf"
        
        # Discover installation
        discover_installation "false" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path"
        
        # Determine upgrade action
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Output the result
        echo "$UPGRADE_STATE"
    )
    
    # Verify state
    if [[ "$result" == "not_installed" ]]; then
        pass "Correctly detected not installed"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Expected NOT_INSTALLED state, got $result"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_dry_run_no_modifications() {
    header "Test: Dry run makes no modifications"
    
    local fixture_dir="${FIXTURES_DIR}/v0.9.0_upgradeable"
    local test_zoneinfo_dir="${fixture_dir}/zoneinfo"
    local test_state_dir="${fixture_dir}/state"
    local test_config_path="${fixture_dir}/tzshim.conf"
    
    # Record file checksums before
    local before_checksums
    before_checksums=$(find "$test_zoneinfo_dir" -type f -exec md5sum {} \; | sort)
    
    # Run in subshell to isolate global state
    (
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Discover and determine action
        discover_installation "false" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path"
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Execute dry run
        execute_upgrade "true" "$test_zoneinfo_dir" "$test_state_dir" "$test_config_path" "${SCRIPT_DIR}/migrations.json" > /dev/null 2>&1
    )
    
    # Record file checksums after
    local after_checksums
    after_checksums=$(find "$test_zoneinfo_dir" -type f -exec md5sum {} \; | sort)
    
    # Verify no changes
    if [[ "$before_checksums" == "$after_checksums" ]]; then
        pass "Dry run made no modifications"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Dry run modified files"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_metadata_preservation() {
    header "Test: Metadata preservation during upgrade"
    
    local fixture_dir="${FIXTURES_DIR}/v0.9.0_upgradeable"
    local test_zoneinfo_dir="${fixture_dir}/zoneinfo"
    local test_state_dir="${fixture_dir}/state"
    local test_config_path="${fixture_dir}/tzshim.conf"
    
    # Get original timezone before upgrade
    local original_tz_before
    original_tz_before=$(grep "^original_timezone=" "$test_config_path" 2>/dev/null | cut -d= -f2 || echo "")
    
    # Create a copy for the upgrade
    local test_copy="${TEST_DIR}/metadata_test"
    cp -r "$fixture_dir" "$test_copy"
    
    # Run in subshell to isolate global state
    (
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Discover and determine action
        discover_installation "false" "${test_copy}/zoneinfo" "${test_copy}/state" "${test_copy}/tzshim.conf"
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Execute upgrade on the copy
        execute_upgrade "false" "${test_copy}/zoneinfo" "${test_copy}/state" "${test_copy}/tzshim.conf" "${SCRIPT_DIR}/migrations.json" > /dev/null 2>&1
    )
    
    # Check if original timezone is preserved in the upgraded copy
    if grep -q "original_timezone=America/Los_Angeles" "${test_copy}/tzshim.conf"; then
        pass "Original timezone metadata preserved"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Original timezone metadata not preserved"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_version_tracking() {
    header "Test: Version tracking after upgrade"
    
    local fixture_dir="${FIXTURES_DIR}/v0.9.0_upgradeable"
    local test_copy="${TEST_DIR}/version_test"
    cp -r "$fixture_dir" "$test_copy"
    
    # Run in subshell to isolate global state
    (
        source "${SCRIPT_DIR}/lib/upgrade.sh"
        
        # Discover and determine action
        discover_installation "false" "${test_copy}/zoneinfo" "${test_copy}/state" "${test_copy}/tzshim.conf"
        determine_upgrade_action "1.0.0" "${SCRIPT_DIR}/migrations.json"
        
        # Execute upgrade
        execute_upgrade "false" "${test_copy}/zoneinfo" "${test_copy}/state" "${test_copy}/tzshim.conf" "${SCRIPT_DIR}/migrations.json" > /dev/null 2>&1
    )
    
    # Check if version is updated
    if grep -q "installed_version=1.0.0" "${test_copy}/tzshim.conf"; then
        pass "Version tracking updated correctly"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        fail "Version tracking not updated"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_locking_mechanism() {
    header "Test: Locking mechanism prevents concurrent operations"
    
    # Source upgrade library
    source "${SCRIPT_DIR}/lib/upgrade.sh"
    
    # Acquire lock
    if acquire_upgrade_lock; then
        # Try to acquire again (should fail)
        if acquire_upgrade_lock 2>/dev/null; then
            fail "Lock allowed concurrent acquisition"
        else
            pass "Lock prevented concurrent operations"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        fi
        
        # Release lock
        release_upgrade_lock
        
        # Should be able to acquire again
        if acquire_upgrade_lock; then
            pass "Lock can be re-acquired after release"
            PASSED_TESTS=$((PASSED_TESTS + 1))
            release_upgrade_lock
        else
            fail "Lock not properly released"
        fi
    else
        fail "Failed to acquire initial lock"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 2))
}

test_unsupported_upgrade() {
    header "Test: Unsupported upgrade path"
    
    # Source upgrade library
    source "${SCRIPT_DIR}/lib/upgrade.sh"
    
    # Try to find upgrade path from non-existent version
    if find_upgrade_path "0.1.0" "1.0.0" "${SCRIPT_DIR}/migrations.json"; then
        fail "Should not find upgrade path from unsupported version"
    else
        pass "Correctly rejected unsupported upgrade path"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

test_downgrade_rejection() {
    header "Test: Downgrade rejection"
    
    # Source upgrade library
    source "${SCRIPT_DIR}/lib/upgrade.sh"
    
    # Try to find downgrade path
    if find_upgrade_path "1.0.0" "0.9.0" "${SCRIPT_DIR}/migrations.json"; then
        fail "Should not allow downgrade"
    else
        pass "Correctly rejected downgrade"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

# ============================================================================
# Main Test Execution
# ============================================================================

main() {
    echo "========================================"
    echo "Canadian Timezone Shim - Upgrade System Tests"
    echo "========================================"
    echo
    
    # Setup
    setup_test_environment
    
    # Isolate HOME so no test can observe or modify the real user installation
    export HOME="$ISOLATED_HOME"
    
    # Run tests
    test_upgrade_detection_current
    echo
    test_upgrade_detection_upgradeable
    echo
    test_upgrade_detection_legacy
    echo
    test_upgrade_detection_corrupted
    echo
    test_upgrade_detection_missing_files
    echo
    test_upgrade_detection_not_installed
    echo
    test_dry_run_no_modifications
    echo
    test_metadata_preservation
    echo
    test_version_tracking
    echo
    test_locking_mechanism
    echo
    test_unsupported_upgrade
    echo
    test_downgrade_rejection
    echo
    
    # Cleanup
    cleanup_test_environment
    
    # Summary
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo "Total tests: $TOTAL_TESTS"
    echo "Passed: $PASSED_TESTS"
    echo "Failed: $((TOTAL_TESTS - PASSED_TESTS))"
    echo
    
    if [[ $PASSED_TESTS -eq $TOTAL_TESTS ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed${NC}"
        exit 1
    fi
}

main "$@"
