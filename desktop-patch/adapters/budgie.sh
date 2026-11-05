#!/usr/bin/env bash
# Budgie adapter for desktop-patch
# Handles Budgie desktop clock configuration

set -euo pipefail

# Budgie adapter metadata
BUDGIE_ADAPTER_NAME="budgie"
BUDGIE_ADAPTER_DISPLAY="Budgie"
BUDGIE_ADAPTER_BACKEND="gsettings"

# Budgie schemas and keys for clock/timezone
BUDGIE_DATETIME_SCHEMA="org.gnome.desktop.datetime"
BUDGIE_CLOCK_SCHEMA="org.gnome.desktop.clock"

# Detect Budgie environment
budgie_detect() {
    local xdg_current="${XDG_CURRENT_DESKTOP:-}"
    local xdg_session="${XDG_SESSION_DESKTOP:-}"
    local desktop_session="${DESKTOP_SESSION:-}"
    
    xdg_current="${xdg_current,,}"
    xdg_session="${xdg_session,,}"
    desktop_session="${desktop_session,,}"
    
    if [[ "$xdg_current" == *"budgie"* ]] || [[ "$xdg_session" == *"budgie"* ]] || \
       [[ "$desktop_session" == *"budgie"* ]]; then
        return 0
    fi
    return 1
}

# Inspect Budgie clock configuration
budgie_inspect() {
    echo "Budgie Clock Configuration:"
    echo ""
    
    if ! check_gsettings_available; then
        echo "  gsettings not available"
        return 1
    fi
    
    # Budgie uses GNOME schemas for datetime
    if gsettings_schema_exists "$BUDGIE_DATETIME_SCHEMA"; then
        echo "Schema: $BUDGIE_DATETIME_SCHEMA"
        
        if gsettings_key_exists "$BUDGIE_DATETIME_SCHEMA" "timezone"; then
            local tz
            tz=$(gsettings get "$BUDGIE_DATETIME_SCHEMA" "timezone" 2>/dev/null)
            echo "  timezone: $tz"
        fi
    else
        echo "  Schema not found: $BUDGIE_DATETIME_SCHEMA"
    fi
    
    echo ""
    return 0
}

# Plan changes for Budgie
budgie_plan() {
    local timezone="$1"
    
    echo "Planned changes for Budgie:"
    echo ""
    echo "Target timezone: $timezone"
    echo ""
    
    if gsettings_schema_exists "$BUDGIE_DATETIME_SCHEMA" && \
       gsettings_key_exists "$BUDGIE_DATETIME_SCHEMA" "timezone"; then
        local current
        current=$(gsettings get "$BUDGIE_DATETIME_SCHEMA" "timezone" 2>/dev/null)
        echo "Will set: $BUDGIE_DATETIME_SCHEMA timezone = '$timezone'"
        echo "  Current value: $current"
    else
        echo "WARNING: Cannot determine the correct GSettings key for timezone."
    fi
    
    echo ""
    return 0
}

# Apply changes for Budgie
budgie_apply() {
    local timezone="$1"
    local state_dir="$2"
    local dry_run="${3:-false}"
    
    if ! check_gsettings_available; then
        echo "ERROR: gsettings not available" >&2
        return 1
    fi
    
    if ! gsettings_schema_exists "$BUDGIE_DATETIME_SCHEMA"; then
        echo "ERROR: Schema not found: $BUDGIE_DATETIME_SCHEMA" >&2
        return 1
    fi
    
    if ! gsettings_key_exists "$BUDGIE_DATETIME_SCHEMA" "timezone"; then
        echo "ERROR: Key not found: timezone" >&2
        return 1
    fi
    
    local current_value
    current_value=$(gsettings get "$BUDGIE_DATETIME_SCHEMA" "timezone" 2>/dev/null) || current_value=""
    local current_clean="${current_value//\'/}"
    
    if [[ "$current_clean" == "$timezone" ]]; then
        echo "Already configured correctly. No changes needed."
        return 0
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        echo "DRY RUN: Would set timezone = '$timezone'"
        echo "DRY RUN: Current value: $current_value"
        return 0
    fi
    
    local manifest
    manifest=$(init_manifest "$state_dir" "budgie" "" \
        "${DETECTED_SESSION_TYPE:-}" "$timezone" "gsettings")
    
    add_manifest_change "$manifest" "schema" \
        "${BUDGIE_DATETIME_SCHEMA}:timezone" \
        "$current_value" "'$timezone'" ""
    
    if ! write_gsettings_value "$BUDGIE_DATETIME_SCHEMA" "timezone" "'$timezone'"; then
        echo "ERROR: Failed to set timezone" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    fi
    
    local actual
    actual=$(gsettings get "$BUDGIE_DATETIME_SCHEMA" "timezone" 2>/dev/null) || {
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
    
    echo "Successfully configured Budgie timezone."
    echo "Timezone set to: $timezone"
    
    return 0
}

# Verify Budgie configuration
budgie_verify() {
    local expected_tz="$1"
    
    if ! check_gsettings_available; then
        return 1
    fi
    
    if ! gsettings_key_exists "$BUDGIE_DATETIME_SCHEMA" "timezone"; then
        return 1
    fi
    
    local actual
    actual=$(gsettings get "$BUDGIE_DATETIME_SCHEMA" "timezone" 2>/dev/null) || return 1
    local actual_clean="${actual//\'/}"
    
    [[ "$actual_clean" == "$expected_tz" ]]
}

# Restore Budgie configuration from manifest
budgie_restore() {
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

# Show status of Budgie configuration
budgie_status() {
    budgie_inspect
}
