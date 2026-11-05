#!/usr/bin/env bash
# GNOME adapter for desktop-patch
# Handles GNOME clock/date configuration

set -euo pipefail

# GNOME adapter metadata
GNOME_ADAPTER_NAME="gnome"
GNOME_ADAPTER_DISPLAY="GNOME"
GNOME_ADAPTER_BACKEND="gsettings"

# GNOME schemas and keys for clock/timezone
GNOME_DATETIME_SCHEMA="org.gnome.desktop.datetime"
GNOME_CLOCK_SCHEMA="org.gnome.desktop.clock"

# Detect GNOME environment
# Returns: 0 if detected, 1 if not
gnome_detect() {
    local xdg_current="${XDG_CURRENT_DESKTOP:-}"
    local xdg_session="${XDG_SESSION_DESKTOP:-}"
    local desktop_session="${DESKTOP_SESSION:-}"
    
    xdg_current="${xdg_current,,}"
    xdg_session="${xdg_session,,}"
    desktop_session="${desktop_session,,}"
    
    if [[ "$xdg_current" == *"gnome"* ]] || [[ "$xdg_session" == *"gnome"* ]] || \
       [[ "$desktop_session" == *"gnome"* ]] || command -v gnome-shell &>/dev/null; then
        return 0
    fi
    return 1
}

# Inspect GNOME clock configuration
gnome_inspect() {
    echo "GNOME Clock Configuration:"
    echo ""
    
    if ! check_gsettings_available; then
        echo "  gsettings not available"
        return 1
    fi
    
    # Check datetime settings
    if gsettings_schema_exists "$GNOME_DATETIME_SCHEMA"; then
        echo "Schema: $GNOME_DATETIME_SCHEMA"
        
        if gsettings_key_exists "$GNOME_DATETIME_SCHEMA" "automatic-timezone"; then
            local auto_tz
            auto_tz=$(gsettings get "$GNOME_DATETIME_SCHEMA" "automatic-timezone" 2>/dev/null)
            echo "  automatic-timezone: $auto_tz"
        fi
        
        if gsettings_key_exists "$GNOME_DATETIME_SCHEMA" "timezone"; then
            local tz
            tz=$(gsettings get "$GNOME_DATETIME_SCHEMA" "timezone" 2>/dev/null)
            echo "  timezone: $tz"
        fi
    else
        echo "  Schema not found: $GNOME_DATETIME_SCHEMA"
    fi
    
    echo ""
    
    # Check clock settings
    if gsettings_schema_exists "$GNOME_CLOCK_SCHEMA"; then
        echo "Schema: $GNOME_CLOCK_SCHEMA"
        
        for key in $(list_gsettings_keys "$GNOME_CLOCK_SCHEMA" 2>/dev/null); do
            local value
            value=$(gsettings get "$GNOME_CLOCK_SCHEMA" "$key" 2>/dev/null)
            echo "  $key: $value"
        done
    else
        echo "  Schema not found: $GNOME_CLOCK_SCHEMA"
    fi
    
    echo ""
    return 0
}

# Plan changes for GNOME
# Arguments: $1 = selected timezone (IANA)
gnome_plan() {
    local timezone="$1"
    
    echo "Planned changes for GNOME:"
    echo ""
    echo "Target timezone: $timezone"
    echo ""
    
    if gsettings_schema_exists "$GNOME_DATETIME_SCHEMA" && \
       gsettings_key_exists "$GNOME_DATETIME_SCHEMA" "timezone"; then
        local current
        current=$(gsettings get "$GNOME_DATETIME_SCHEMA" "timezone" 2>/dev/null)
        echo "Will set: $GNOME_DATETIME_SCHEMA timezone = '$timezone'"
        echo "  Current value: $current"
    else
        echo "WARNING: Cannot determine the correct GSettings key for timezone."
        echo "  GNOME may not expose a writable timezone key via gsettings."
        echo "  The clock may already respect the system TZif data."
    fi
    
    echo ""
    echo "Why: GNOME's clock reads timezone from GSettings or the system."
    echo "     If the system timezone is already correct (via /etc/localtime),"
    echo "     no change may be needed."
    echo ""
    
    return 0
}

# Apply changes for GNOME
# Arguments: $1 = timezone, $2 = state dir, $3 = dry run
gnome_apply() {
    local timezone="$1"
    local state_dir="$2"
    local dry_run="${3:-false}"
    
    if ! check_gsettings_available; then
        echo "ERROR: gsettings not available" >&2
        return 1
    fi
    
    # Check if the key exists and is writable
    if ! gsettings_schema_exists "$GNOME_DATETIME_SCHEMA"; then
        echo "ERROR: Schema not found: $GNOME_DATETIME_SCHEMA" >&2
        echo "GNOME may not support programmatic timezone changes." >&2
        return 1
    fi
    
    if ! gsettings_key_exists "$GNOME_DATETIME_SCHEMA" "timezone"; then
        echo "ERROR: Key not found: timezone" >&2
        return 1
    fi
    
    # Read current value
    local current_value
    current_value=$(gsettings get "$GNOME_DATETIME_SCHEMA" "timezone" 2>/dev/null) || current_value=""
    
    # Strip quotes for comparison
    local current_clean="${current_value//\'/}"
    
    # Check if already set correctly
    if [[ "$current_clean" == "$timezone" ]]; then
        echo "Already configured correctly. No changes needed."
        return 0
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        echo "DRY RUN: Would set timezone = '$timezone'"
        echo "DRY RUN: Current value: $current_value"
        return 0
    fi
    
    # Initialize manifest
    local manifest
    manifest=$(init_manifest "$state_dir" "gnome" "" \
        "${DETECTED_SESSION_TYPE:-}" "$timezone" "gsettings")
    
    # Record original value
    add_manifest_change "$manifest" "schema" \
        "${GNOME_DATETIME_SCHEMA}:timezone" \
        "$current_value" "'$timezone'" ""
    
    # Write the value
    if ! write_gsettings_value "$GNOME_DATETIME_SCHEMA" "timezone" "'$timezone'"; then
        echo "ERROR: Failed to set timezone" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    fi
    
    # Verify
    local actual
    actual=$(gsettings get "$GNOME_DATETIME_SCHEMA" "timezone" 2>/dev/null) || {
        echo "ERROR: Verification failed" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    }
    
    local actual_clean="${actual//\'/}"
    if [[ "$actual_clean" != "$timezone" ]]; then
        echo "ERROR: Verification failed - value mismatch" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    fi
    
    finalize_manifest "$manifest" "success" "false" "false"
    
    echo "Successfully configured GNOME timezone."
    echo "Timezone set to: $timezone"
    echo ""
    echo "Note: The change should take effect immediately."
    echo "      No restart is typically required."
    
    return 0
}

# Verify GNOME configuration
# Arguments: $1 = expected timezone
gnome_verify() {
    local expected_tz="$1"
    
    if ! check_gsettings_available; then
        return 1
    fi
    
    if ! gsettings_key_exists "$GNOME_DATETIME_SCHEMA" "timezone"; then
        return 1
    fi
    
    local actual
    actual=$(gsettings get "$GNOME_DATETIME_SCHEMA" "timezone" 2>/dev/null) || return 1
    local actual_clean="${actual//\'/}"
    
    [[ "$actual_clean" == "$expected_tz" ]]
}

# Restore GNOME configuration from manifest
# Arguments: $1 = manifest file
gnome_restore() {
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

# Show status of GNOME configuration
gnome_status() {
    gnome_inspect
}
