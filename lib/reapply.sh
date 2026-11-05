#!/usr/bin/env bash
# Canadian Timezone Shim - Reapply script (v2)
# Called by the systemd path unit whenever tzdata files change.
# Rebuilds every custom Canadian/* zone recorded in the system manifest
# from its freshly updated IANA source. Never touches unowned files.

set -euo pipefail

STATE_DIR="/var/lib/canadian-tz-shim"
EXEC_DIR="/usr/local/libexec/canadian-tz-shim"
CONFIG_FILE="/usr/local/share/canadian-tz-shim/zones.conf"
PATCHER="${EXEC_DIR}/patch_tzif.py"
CZ_LIB="${EXEC_DIR}/custom_zones.sh"

# Fall back to source-tree paths if the exec dir copy is missing
# (only happens when running the script from a checkout).
if [[ ! -f "$CZ_LIB" ]]; then
    CZ_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/custom_zones.sh"
    CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zones.conf"
    PATCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/patch_tzif.py"
fi

log() { logger -t canadian-tz-shim "$@"; }

if [[ ! -f "$CZ_LIB" ]]; then log "ERROR: custom_zones.sh missing"; exit 1; fi
if [[ ! -f "$PATCHER" ]];  then log "ERROR: patch_tzif.py missing";  exit 1; fi
if [[ ! -f "$CONFIG_FILE" ]]; then log "ERROR: zones.conf missing";  exit 1; fi
if ! command -v python3 >/dev/null 2>&1; then
    log "ERROR: python3 not available"; exit 1
fi

# shellcheck source=/dev/null
source "$CZ_LIB"

# Only rebuild if the system manifest exists (we installed at least once).
manifest="$(custom_zones_manifest_path system)"
if [[ ! -f "$manifest" ]]; then
    log "No manifest — nothing to reapply"
    exit 0
fi

# Read the selected custom zone (if any) for /etc/localtime refresh.
selected_custom=""
if [[ -f "${STATE_DIR}/selected-custom-zone" ]]; then
    selected_custom=$(<"${STATE_DIR}/selected-custom-zone")
fi

log "Rebuilding custom zones from tzdata updates"
rc=0
if ! custom_zones_rebuild_all system "$PATCHER" "$CONFIG_FILE" 2>&1 | \
        while IFS= read -r line; do log "$line"; done; then
    rc=1
fi

# Re-link /etc/localtime only if it still points into our territory AND the
# selected custom id is still installed under /usr/share/zoneinfo/Canadian/.
if [[ -n "$selected_custom" ]] && [[ -L /etc/localtime ]]; then
    current=$(readlink /etc/localtime 2>/dev/null || echo "")
    case "$current" in
        /usr/share/zoneinfo/*)
            target="/usr/share/zoneinfo/${selected_custom}"
            if [[ -f "$target" ]]; then
                ln -sfn "$target" /etc/localtime
                log "Re-linked /etc/localtime → ${selected_custom}"
            else
                log "Selected custom zone $selected_custom missing; /etc/localtime unchanged"
            fi
            ;;
        *) log "/etc/localtime points elsewhere; leaving alone" ;;
    esac
fi

exit $rc
