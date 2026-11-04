#!/usr/bin/env bash
# Canadian Timezone Shim - Reapply script
# Called by systemd service when tzdata updates
# Non-interactive: uses stored state to re-patch

set -euo pipefail

STATE_DIR="/var/lib/canadian-tz-shim"
STATE_FILE="${STATE_DIR}/selected-zone"
CONFIG_FILE="/usr/local/share/canadian-tz-shim/zones.conf"
ZONEINFO_DIR="/usr/local/share/zoneinfo"
PATCH_SCRIPT="/usr/local/libexec/canadian-tz-shim/patch_tzif.py"

# Determine config file location (system-wide vs user)
if [[ ! -f "$CONFIG_FILE" ]]; then
    CONFIG_FILE="$(dirname "${BASH_SOURCE[0]}")/../zones.conf"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t canadian-tz-shim "Config file not found, cannot reapply"
    exit 1
fi

# Require the Python patcher script
if [[ ! -f "$PATCH_SCRIPT" ]]; then
    logger -t canadian-tz-shim "ERROR: Patcher script not found: $PATCH_SCRIPT"
    logger -t canadian-tz-shim "Cannot reapply without the TZif-aware patcher"
    exit 1
fi

# Verify Python3 is available
if ! command -v python3 &>/dev/null; then
    logger -t canadian-tz-shim "ERROR: python3 not found, required for patching"
    exit 1
fi

# Read selected zone from state file
if [[ ! -f "$STATE_FILE" ]]; then
    logger -t canadian-tz-shim "No selected zone found, cannot reapply"
    exit 0
fi

selected_zone=$(cat "$STATE_FILE")

# Re-patch all installed zones
while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue

    system_zone="/usr/share/zoneinfo/${iana_zone}"
    target_zone="${ZONEINFO_DIR}/${iana_zone}"
    temp_zone="${ZONEINFO_DIR}/${iana_zone}.tmp"

    # Only re-patch if the target zone exists (was previously installed)
    if [[ ! -f "$target_zone" ]]; then
        continue
    fi

    if [[ ! -f "$system_zone" ]]; then
        logger -t canadian-tz-shim "System zone not found: $system_zone"
        continue
    fi

    # Validate source timezone file
    if ! zdump -v "$system_zone" &>/dev/null; then
        logger -t canadian-tz-shim "Invalid source timezone file: $system_zone"
        continue
    fi

    # Stage replacement in temporary location
    cp "$system_zone" "$temp_zone"

    # Use the required Python patcher
    patch_count=$(python3 "$PATCH_SCRIPT" "$temp_zone" "$iana_abbrev" "$official_abbrev" 2>/dev/null) || patch_count=0

    if [[ "$patch_count" -gt 0 ]]; then
        # Verify the patch worked
        verify_year="2026"
        if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
            verify_year="2020"
        fi

        zdump_output=$(zdump -v "$temp_zone" 2>/dev/null)
        if echo "$zdump_output" | grep -q "$verify_year.*$official_abbrev"; then
            # Validate UTC offset
            expected_offset=""
            case "$official_abbrev" in
                PCT) expected_offset="-0700" ;;
                ABT) expected_offset="-0600" ;;
                YST) expected_offset="-0700" ;;
                MBT) expected_offset="-0500" ;;
                NWT) expected_offset="-0600" ;;
            esac

            if [[ -n "$expected_offset" ]]; then
                # Test a date after the transition
                test_date="2026-12-15"
                if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
                    test_date="2021-06-15"
                fi

                actual_offset=$(TZ="$temp_zone" date -d "$test_date 12:00:00" +"%z" 2>/dev/null || echo "")
                if [[ "$actual_offset" != "$expected_offset" ]]; then
                    logger -t canadian-tz-shim "UTC offset mismatch for $iana_zone (expected $expected_offset, got $actual_offset)"
                    rm -f "$temp_zone"
                    # Restore from backup if available
                    if [[ -f "${target_zone}.backup" ]]; then
                        cp "${target_zone}.backup" "$target_zone"
                        logger -t canadian-tz-shim "Restored $iana_zone from backup"
                    fi
                    continue
                fi
            fi
            
            # Atomic replacement: backup original and replace
            if [[ -f "$target_zone" ]]; then
                cp "$target_zone" "${target_zone}.backup.$(date +%s)"
            fi
            mv "$temp_zone" "$target_zone"
            
            logger -t canadian-tz-shim "Re-patched $iana_zone ($iana_abbrev → $official_abbrev, $patch_count locations)"
        else
            logger -t canadian-tz-shim "Failed to verify patch for $iana_zone"
            rm -f "$temp_zone"
            # Restore from backup if available
            if [[ -f "${target_zone}.backup" ]]; then
                cp "${target_zone}.backup" "$target_zone"
                logger -t canadian-tz-shim "Restored $iana_zone from backup"
            fi
        fi
    else
        logger -t canadian-tz-shim "Failed to patch $iana_zone"
        rm -f "$temp_zone"
        # Restore from backup if available
        if [[ -f "${target_zone}.backup" ]]; then
            cp "${target_zone}.backup" "$target_zone"
            logger -t canadian-tz-shim "Restored $iana_zone from backup"
        fi
    fi

    # Re-apply symlink only for the selected zone
    if [[ "$iana_zone" == "$selected_zone" ]]; then
        if [[ -L /etc/localtime ]]; then
            ln -sf "$target_zone" /etc/localtime
            logger -t canadian-tz-shim "Re-linked /etc/localtime → $iana_zone"
        fi
    fi

done < "$CONFIG_FILE"
