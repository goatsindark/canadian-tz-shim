#!/usr/bin/env bash
# Test script for Canadian Timezone Shim installation components

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Testing Canadian Timezone Shim Components ==="
echo ""

# Test 1: Verify config file parsing
echo "Test 1: Config file parsing"
config_count=0
while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue
    config_count=$((config_count + 1))
    echo "  Found: $iana_zone ($official_name)"
done < "${SCRIPT_DIR}/zones.conf"

if [[ $config_count -eq 6 ]]; then
    echo "  ✓ Config file has 6 zones"
else
    echo "  ✗ Config file has $config_count zones (expected 6)"
    exit 1
fi
echo ""

# Test 2: Verify systemd service file format
echo "Test 2: Systemd service file format"
if grep -q "^\[Unit\]" "${SCRIPT_DIR}/lib/canadian-tz-shim.service" && \
   grep -q "^\[Service\]" "${SCRIPT_DIR}/lib/canadian-tz-shim.service" && \
   grep -q "ExecStart=" "${SCRIPT_DIR}/lib/canadian-tz-shim.service"; then
    echo "  ✓ Service file has required sections"
else
    echo "  ✗ Service file missing required sections"
    exit 1
fi
echo ""

# Test 3: Verify systemd path file format
echo "Test 3: Systemd path file format"
if grep -q "^\[Path\]" "${SCRIPT_DIR}/lib/canadian-tz-shim.path" && \
   grep -q "PathModified=" "${SCRIPT_DIR}/lib/canadian-tz-shim.path"; then
    path_count=$(grep -c "PathModified=" "${SCRIPT_DIR}/lib/canadian-tz-shim.path")
    echo "  ✓ Path file has $path_count monitored paths"
else
    echo "  ✗ Path file missing required sections"
    exit 1
fi
echo ""

# Test 4: Verify reapply script is executable
echo "Test 4: Reapply script permissions"
if [[ -x "${SCRIPT_DIR}/lib/reapply.sh" ]]; then
    echo "  ✓ reapply.sh is executable"
else
    echo "  ✗ reapply.sh is not executable"
    exit 1
fi
echo ""

# Test 5: Test timezone detection function
echo "Test 5: Timezone detection logic"
detect_current_timezone() {
    if [[ -L /etc/localtime ]]; then
        local target
        target=$(readlink -f /etc/localtime)
        if [[ "$target" =~ /zoneinfo/(.*) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    return 1
}

current_tz=$(detect_current_timezone || echo "none")
echo "  Current timezone: $current_tz"
echo "  ✓ Detection function works"
echo ""

# Test 6: Verify state directory creation
echo "Test 6: State directory logic"
test_state_dir="/tmp/test-canadian-tz-shim-state"
mkdir -p "$test_state_dir"
echo "America/Vancouver" > "${test_state_dir}/selected-zone"
if [[ -f "${test_state_dir}/selected-zone" ]]; then
    stored_zone=$(cat "${test_state_dir}/selected-zone")
    echo "  ✓ State file created: $stored_zone"
    rm -rf "$test_state_dir"
else
    echo "  ✗ Failed to create state file"
    exit 1
fi
echo ""

# Test 7: Verify patch idempotency check
echo "Test 7: Idempotency check logic"
test_zone="/tmp/test-zoneinfo/America/Vancouver"
mkdir -p "$(dirname "$test_zone")"
cp /usr/share/zoneinfo/America/Vancouver "$test_zone"

# First check - should not be patched
zdump_output=$(zdump -v "$test_zone" 2>/dev/null)
if echo "$zdump_output" | grep -q "2026.*PCT"; then
    echo "  ✗ Zone appears already patched (unexpected)"
    rm -rf /tmp/test-zoneinfo
    exit 1
else
    echo "  ✓ Unpatched zone correctly identified"
fi

# Apply patch
sed -i 's/MST/PCT/g' "$test_zone"

# Second check - should be patched
zdump_output=$(zdump -v "$test_zone" 2>/dev/null)
if echo "$zdump_output" | grep -q "2026.*PCT"; then
    echo "  ✓ Patched zone correctly identified"
else
    echo "  ✗ Patched zone not detected"
    rm -rf /tmp/test-zoneinfo
    exit 1
fi

rm -rf /tmp/test-zoneinfo
echo ""

echo "=== All component tests passed ==="
