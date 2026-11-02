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

    # Copy fresh from system and patch
    cp "$system_zone" "$target_zone"

    # Use the required Python patcher
    patch_count=$(python3 "$PATCH_SCRIPT" "$target_zone" "$iana_abbrev" "$official_abbrev" 2>/dev/null) || patch_count=0

    if [[ "$patch_count" -gt 0 ]]; then
        # Verify the patch worked
        verify_year="2026"
        if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
            verify_year="2020"
        fi

        zdump_output=$(zdump -v "$target_zone" 2>/dev/null)
        if echo "$zdump_output" | grep -q "$verify_year.*$official_abbrev"; then
            logger -t canadian-tz-shim "Re-patched $iana_zone ($iana_abbrev → $official_abbrev, $patch_count locations)"
        else
            logger -t canadian-tz-shim "Failed to verify patch for $iana_zone"
            # Restore from backup if available
            if [[ -f "${target_zone}.backup" ]]; then
                cp "${target_zone}.backup" "$target_zone"
                logger -t canadian-tz-shim "Restored $iana_zone from backup"
            fi
        fi
    else
        logger -t canadian-tz-shim "Failed to patch $iana_zone"
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
