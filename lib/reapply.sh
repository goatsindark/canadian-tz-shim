#!/usr/bin/env bash
# Canadian Timezone Shim - Reapply script
# Called by systemd service when tzdata updates
# Non-interactive: uses stored state to re-patch

set -euo pipefail

STATE_DIR="/var/lib/canadian-tz-shim"
STATE_FILE="${STATE_DIR}/selected-zone"
CONFIG_FILE="/usr/local/share/canadian-tz-shim/zones.conf"
ZONEINFO_DIR="/usr/local/share/zoneinfo"

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

# Re-patch the selected zone
while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue
    
    if [[ "$iana_zone" != "$selected_zone" ]]; then
        continue
    fi
    
    system_zone="/usr/share/zoneinfo/${iana_zone}"
    target_zone="${ZONEINFO_DIR}/${iana_zone}"
    
    if [[ ! -f "$system_zone" ]]; then
        logger -t canadian-tz-shim "System zone not found: $system_zone"
        exit 1
    fi
    
    mkdir -p "$(dirname "$target_zone")"
    cp "$system_zone" "$target_zone"
    sed -i "s/$iana_abbrev/$official_abbrev/g" "$target_zone"
    
    # Re-apply symlink
    if [[ -L /etc/localtime ]]; then
        current_target=$(readlink -f /etc/localtime)
        if [[ "$current_target" == *"$iana_zone"* ]]; then
            ln -sf "$target_zone" /etc/localtime
            logger -t canadian-tz-shim "Re-patched and re-linked $iana_zone"
        fi
    fi
    
    logger -t canadian-tz-shim "Re-patched $iana_zone ($iana_abbrev → $official_abbrev)"
    
done < "$CONFIG_FILE"
