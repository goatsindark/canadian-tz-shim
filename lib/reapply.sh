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

    # Copy fresh from system and patch
    cp "$system_zone" "$target_zone"

    if [[ -f "$PATCH_SCRIPT" ]]; then
        patch_count=$(python3 "$PATCH_SCRIPT" "$target_zone" "$iana_abbrev" "$official_abbrev" 2>/dev/null) || patch_count=0
    else
        # Fallback to sed if patch script not available
        sed -i "s/$iana_abbrev/$official_abbrev/g" "$target_zone"
        patch_count=1
    fi

    if [[ "$patch_count" -gt 0 ]]; then
        logger -t canadian-tz-shim "Re-patched $iana_zone ($iana_abbrev → $official_abbrev, $patch_count locations)"
    else
        logger -t canadian-tz-shim "Failed to patch $iana_zone"
    fi

    # Re-apply symlink only for the selected zone
    if [[ "$iana_zone" == "$selected_zone" ]]; then
        if [[ -L /etc/localtime ]]; then
            ln -sf "$target_zone" /etc/localtime
            logger -t canadian-tz-shim "Re-linked /etc/localtime → $iana_zone"
        fi
    fi

done < "$CONFIG_FILE"
