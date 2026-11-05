#!/usr/bin/env bash
# MATE adapter for desktop-patch
# Handles MATE desktop clock configuration

set -euo pipefail

# MATE adapter metadata
MATE_ADAPTER_NAME="mate"
MATE_ADAPTER_DISPLAY="MATE"
MATE_ADAPTER_BACKEND="gsettings"

# MATE schemas and keys for clock/timezone
MATE_CLOCK_SCHEMA="org.mate.panel.applet.clock"

# Detect MATE environment
mate_detect() {
    local xdg_current="${XDG_CURRENT_DESKTOP:-}"
    local xdg_session="${XDG_SESSION_DESKTOP:-}"
    local desktop_session="${DESKTOP_SESSION:-}"
    
    xdg_current="${xdg_current,,}"
    xdg_session="${xdg_session,,}"
    desktop_session="${desktop_session,,}"
    
    if [[ "$xdg_current" == *"mate"* ]] || [[ "$xdg_session" == *"mate"* ]] || \
       [[ "$desktop_session" == *"mate"* ]]; then
        return 0
    fi
    return 1
}

# Inspect MATE clock configuration
mate_inspect() {
    echo "MATE Clock Configuration:"
    echo ""
    
    if ! check_gsettings_available; then
        echo "  gsettings not available"
        return 1
    fi
    
    if gsettings_schema_exists "$MATE_CLOCK_SCHEMA"; then
        echo "Schema: $MATE_CLOCK_SCHEMA"
        
        for key in $(list_gsettings_keys "$MATE_CLOCK_SCHEMA" 2>/dev/null); do
            local value
            value=$(gsettings get "$MATE_CLOCK_SCHEMA" "$key" 2>/dev/null)
            echo "  $key: $value"
        done
    else
        echo "  Schema not found: $MATE_CLOCK_SCHEMA"
        echo "  MATE clock applet may use dconf paths instead of GSettings schemas."
    fi
    
    echo ""
    return 0
}

# Plan changes for MATE
mate_plan() {
    local timezone="$1"
    
    echo "Planned changes for MATE:"
    echo ""
    echo "Target timezone: $timezone"
    echo ""
    
    if gsettings_schema_exists "$MATE_CLOCK_SCHEMA"; then
        echo "Will attempt to set timezone via GSettings schema."
    else
        echo "WARNING: MATE clock applet may not expose a writable timezone key."
        echo "  The clock may already respect the system TZif data."
    fi
    
    echo ""
    return 0
}

# Apply changes for MATE
mate_apply() {
    local timezone="$1"
    local state_dir="$2"
    local dry_run="${3:-false}"
    
    if ! check_gsettings_available; then
        echo "ERROR: gsettings not available" >&2
        return 1
    fi
    
    if ! gsettings_schema_exists "$MATE_CLOCK_SCHEMA"; then
        echo "WARNING: Schema not found: $MATE_CLOCK_SCHEMA" >&2
        echo "MATE clock applet may not support programmatic timezone changes." >&2
        echo "The clock may already respect the system TZif data." >&2
        return 0
    fi
    
    # Try to find a timezone key
    local tz_key=""
    for key in $(list_gsettings_keys "$MATE_CLOCK_SCHEMA" 2>/dev/null); do
        if [[ "$key" == *"timezone"* ]] || [[ "$key" == *"tz"* ]]; then
            tz_key="$key"
            break
        fi
    done
    
    if [[ -z "$tz_key" ]]; then
        echo "WARNING: No timezone key found in $MATE_CLOCK_SCHEMA" >&2
        return 0
    fi
    
    local current_value
    current_value=$(gsettings get "$MATE_CLOCK_SCHEMA" "$tz_key" 2>/dev/null) || current_value=""
    local current_clean="${current_value//\'/}"
    
    if [[ "$current_clean" == "$timezone" ]]; then
        echo "Already configured correctly. No changes needed."
        return 0
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        echo "DRY RUN: Would set $tz_key = '$timezone'"
        echo "DRY RUN: Current value: $current_value"
        return 0
    fi
    
    local manifest
    manifest=$(init_manifest "$state_dir" "mate" "" \
        "${DETECTED_SESSION_TYPE:-}" "$timezone" "gsettings")
    
    add_manifest_change "$manifest" "schema" \
        "${MATE_CLOCK_SCHEMA}:${tz_key}" \
        "$current_value" "'$timezone'" ""
    
    if ! write_gsettings_value "$MATE_CLOCK_SCHEMA" "$tz_key" "'$timezone'"; then
        echo "ERROR: Failed to set timezone" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    fi
    
    finalize_manifest "$manifest" "success" "true" "false"
    
    echo "Successfully configured MATE timezone."
    echo "Timezone set to: $timezone"
    
    return 0
}

# Verify MATE configuration
mate_verify() {
    local expected_tz="$1"
    
    if ! check_gsettings_available; then
        return 1
    fi
    
    if ! gsettings_schema_exists "$MATE_CLOCK_SCHEMA"; then
        return 1
    fi
    
    # Try to find a timezone key
    local tz_key=""
    for key in $(list_gsettings_keys "$MATE_CLOCK_SCHEMA" 2>/dev/null); do
        if [[ "$key" == *"timezone"* ]] || [[ "$key" == *"tz"* ]]; then
            tz_key="$key"
            break
        fi
    done
    
    if [[ -z "$tz_key" ]]; then
        return 1
    fi
    
    local actual
    actual=$(gsettings get "$MATE_CLOCK_SCHEMA" "$tz_key" 2>/dev/null) || return 1
    local actual_clean="${actual//\'/}"
    
    [[ "$actual_clean" == "$expected_tz" ]]
}

# Restore MATE configuration from manifest
mate_restore() {
    local manifest="$1"
    
    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: Manifest not found: $manifest" >&2
        return 1
    fi
    
    local changes
    changes=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for change in data.get('changes', []):
    if change.get('type') == 'schema':
        print(f\"{change['target']}|{change['original_value']}\")
" "$manifest" 2>/dev/null) || {
        echo "ERROR: Failed to read manifest" >&2
        return 1
    }
    
    if [[ -z "$changes" ]]; then
        echo "No changes to restore."
        return 0
    fi
    
    while IFS='|' read -r target original_value; do
        [[ -z "$target" ]] && continue
        
        local schema key
        IFS=':' read -r schema key <<< "$target"
        
        if write_gsettings_value "$schema" "$key" "$original_value"; then
            echo "Restored $schema $key to $original_value"
        else
            echo "WARNING: Failed to restore $target"
        fi
    done <<< "$changes"
    
    echo "Restoration complete."
    return 0
}

# Show status of MATE configuration
mate_status() {
    mate_inspect
}
