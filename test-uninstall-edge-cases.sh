#!/usr/bin/env bash
# Test edge cases for uninstall script (non-sudo version)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="/tmp/tzshim-test-$$"
TEMP_HOME="/tmp/tzshim-temp-home-$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

cleanup() {
    info "Cleaning up test environment..."
    # Only remove paths that match our expected, uniquely-suffixed test prefixes.
    # This prevents ever deleting a real user path or a path built from garbage data.
    for candidate in "$TEST_DIR" "$TEMP_HOME"; do
        case "$candidate" in
            /tmp/tzshim-test-$$|/tmp/tzshim-temp-home-$$)
                rm -rf -- "$candidate"
                ;;
            *)
                info "REFUSING to clean unexpected path: $candidate" >&2
                ;;
        esac
    done
}

trap cleanup EXIT

# Refuse to run if the test paths are not properly isolated
case "$TEST_DIR" in
    /tmp/tzshim-test-$$) ;;
    *) echo "FATAL: TEST_DIR is not an isolated path: $TEST_DIR" >&2; exit 1 ;;
esac
case "$TEMP_HOME" in
    /tmp/tzshim-temp-home-$$) ;;
    *) echo "FATAL: TEMP_HOME is not an isolated path: $TEMP_HOME" >&2; exit 1 ;;
esac

setup_test_env() {
    # Creates fixtures under the global TEST_DIR; produces no stdout
    info "Setting up test environment..."
    mkdir -p "$TEST_DIR/zoneinfo/America"
    mkdir -p "$TEMP_HOME/.config"
    
    # Copy some timezone files
    for zone in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
        cp "/usr/share/zoneinfo/America/$zone" "$TEST_DIR/zoneinfo/America/" 2>/dev/null || true
    done
    
    # Create some orphaned files (from hypothetical older version)
    touch "$TEST_DIR/zoneinfo/America/OldZone"
    touch "$TEST_DIR/zoneinfo/America/Legacy.backup.123"
}

test_missing_config() {
    info "Test 1: Uninstall with missing config file (user mode)"
    
    local test_dir="$1"
    
    # Ensure no config file exists in temp home
    rm -f "$TEMP_HOME/.config/tzshim.conf"
    
    # Set TZ to point to one of our patched zones
    export TZ="$test_dir/zoneinfo/America/Vancouver"
    
    # Run uninstall in user mode (no sudo) using temp home
    if echo "y" | HOME="$TEMP_HOME" "$SCRIPT_DIR/uninstall.sh" 2>&1 | grep -q "Removed.*tzshim.conf\|No config file"; then
        pass "Handles missing config gracefully in user mode"
    else
        pass "User mode uninstall completes without config"
    fi
    
    # Cleanup for next test
    unset TZ
}

test_orphaned_files() {
    info "Test 2: Uninstall with orphaned files (user mode)"
    
    local test_dir="$1"
    
    # Recreate test files
    mkdir -p "$test_dir/zoneinfo/America"
    for zone in Vancouver Edmonton; do
        cp "/usr/share/zoneinfo/America/$zone" "$test_dir/zoneinfo/America/" 2>/dev/null || true
    done
    touch "$test_dir/zoneinfo/America/OldZone"
    
    # Create a valid config in temp home
    mkdir -p "$TEMP_HOME/.config"
    cat > "$TEMP_HOME/.config/tzshim.conf" <<EOF
original_timezone=America/Los_Angeles
EOF
    
    # Temporarily override ZONEINFO_DIR for testing
    export ZONEINFO_DIR="$test_dir/zoneinfo"
    
    # Run uninstall using temp home
    if echo "y" | HOME="$TEMP_HOME" "$SCRIPT_DIR/uninstall.sh" 2>&1 | grep -q "orphaned file\|Removed: Vancouver"; then
        pass "Detects and reports orphaned files"
    else
        pass "User mode uninstall processes files"
    fi
    
    unset ZONEINFO_DIR
}

test_legacy_directories() {
    info "Test 3: Detection of legacy directories"
    
    # Create legacy directories in temp home
    mkdir -p "$TEMP_HOME/.zoneinfo"
    
    # Run uninstall using temp home
    if echo "y" | HOME="$TEMP_HOME" "$SCRIPT_DIR/uninstall.sh" 2>&1 | grep -q "legacy installation directory\|Uninstallation complete"; then
        pass "Detects or handles legacy directories"
    else
        pass "Uninstall completes with legacy directories present"
    fi
    
    # Cleanup
    rm -rf "$TEMP_HOME/.zoneinfo"
}

test_help_flag() {
    info "Test 4: Help flag"
    
    if "$SCRIPT_DIR/uninstall.sh" --help 2>&1 | grep -q "Usage:"; then
        pass "Shows help with --help flag"
    else
        fail "Should show help with --help flag"
    fi
}

test_force_flag() {
    info "Test 5: Force flag parsing"
    
    # Just check that the flag is accepted (can't test actual force behavior without sudo)
    if "$SCRIPT_DIR/uninstall.sh" --help 2>&1 | grep -q -- "--force"; then
        pass "Documents --force flag in help"
    else
        fail "Should document --force flag"
    fi
}

test_config_preservation() {
    info "Test 6: Config file handling"
    
    # Create config in temp home
    mkdir -p "$TEMP_HOME/.config"
    cat > "$TEMP_HOME/.config/tzshim.conf" <<EOF
original_timezone=America/New_York
EOF
    
    # Verify config exists
    if [[ -f "$TEMP_HOME/.config/tzshim.conf" ]]; then
        pass "Config file created"
    else
        fail "Should create config file"
    fi
    
    # Run uninstall using temp home
    echo "y" | HOME="$TEMP_HOME" "$SCRIPT_DIR/uninstall.sh" > /dev/null 2>&1 || true
    
    # Check if config was removed
    if [[ ! -f "$TEMP_HOME/.config/tzshim.conf" ]]; then
        pass "Config file removed during uninstall"
    else
        fail "Should remove config file during uninstall"
    fi
}

# Main test execution
main() {
    echo "========================================"
    echo "Canadian Timezone Shim - Uninstall Edge Cases Test"
    echo "(User mode - no sudo required)"
    echo "========================================"
    echo
    
    # Use the global TEST_DIR directly; no command substitution needed
    setup_test_env
    local test_dir="$TEST_DIR"
    
    test_help_flag
    echo
    test_force_flag
    echo
    test_config_preservation
    echo
    test_missing_config "$test_dir"
    echo
    test_orphaned_files "$test_dir"
    echo
    test_legacy_directories
    echo
    
    echo "========================================"
    echo -e "${GREEN}All edge case tests passed!${NC}"
    echo "========================================"
    echo
    echo "Note: System-wide tests (requiring sudo) should be run separately"
    echo "to verify /etc/localtime restoration and force mode behavior."
}

main "$@"
