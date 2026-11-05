#!/usr/bin/env bash
# XFCE adapter for desktop-patch
# Handles XFCE panel clock configuration

set -euo pipefail

# XFCE adapter metadata
XFCE_ADAPTER_NAME="xfce"
XFCE_ADAPTER_DISPLAY="XFCE"
XFCE_ADAPTER_BACKEND="xfconf"

# Detect XFCE environment
xfce_detect() {
    local xdg_current="${XDG_CURRENT_DESKTOP:-}"
    local xdg_session="${XDG_SESSION_DESKTOP:-}"
    local desktop_session="${DESKTOP_SESSION:-}"
    
    xdg_current="${xdg_current,,}"
    xdg_session="${xdg_session,,}"
    desktop_session="${desktop_session,,}"
    
    if [[ "$xdg_current" == *"xfce"* ]] || [[ "$xdg_session" == *"xfce"* ]] || \
       [[ "$desktop_session" == *"xfce"* ]]; then
        return 0
    fi
    return 1
}

# Inspect XFCE clock configuration
xfce_inspect() {
    echo "XFCE Clock Configuration:"
    echo ""
    
    if ! check_xfconf_available; then
        echo "  xfconf-query not available"
        return 1
    fi
    
    local channel="xfce4-panel"
    
    if ! xfconf_channel_exists "$channel"; then
        echo "  Channel not found: $channel"
        return 1
    fi
    
    echo "Channel: $channel"
    echo ""
    echo "Clock plugins found:"
    
    local plugins
    plugins=$(find_xfce_clock_plugins) || {
        echo "  (none found)"
        return 0
    }
    
    local count=0
    while IFS= read -r plugin; do
        [[ -z "$plugin" ]] && continue
        count=$((count + 1))
        
        echo ""
        echo "  Plugin $count: $plugin"
        
        # Read timezone-related properties
        local tz
        tz=$(read_xfconf_value "$channel" "${plugin}/Timezone") || tz="(not set)"
        echo "    timezone: $tz"
        
    done <<< "$plugins"
    
    if [[ "$count" -eq 0 ]]; then
        echo "  (none found)"
    fi
    
    echo ""
    return 0
}

# Plan changes for XFCE
# Arguments: $1 = selected timezone, $2 = plugin index (optional)
xfce_plan() {
    local timezone="$1"
    local plugin_index="${2:-}"
    
    echo "Planned changes for XFCE:"
    echo ""
    echo "Target timezone: $timezone"
    echo ""
    
    local plugins
    plugins=$(find_xfce_clock_plugins) || {
        echo "ERROR: No clock plugins found" >&2
        return 1
    }
    
    local plugin_array=()
    while IFS= read -r plugin; do
        [[ -n "$plugin" ]] && plugin_array+=("$plugin")
    done <<< "$plugins"
    
    if [[ ${#plugin_array[@]} -eq 0 ]]; then
        echo "ERROR: No clock plugins found" >&2
        return 1
    fi
    
    if [[ -n "$plugin_index" ]]; then
        if [[ "$plugin_index" -lt 1 ]] || [[ "$plugin_index" -gt ${#plugin_array[@]} ]]; then
            echo "ERROR: Invalid plugin index: $plugin_index" >&2
            return 1
        fi
        local target="${plugin_array[$((plugin_index - 1))]}"
        echo "Will modify plugin: $target"
        echo "  Setting timezone = $timezone"
    else
        echo "Clock plugins to modify:"
        local i
        for i in $(seq 1 ${#plugin_array[@]}); do
            echo "  $i) ${plugin_array[$((i - 1))]}"
        done
        echo ""
        echo "Each plugin will have its timezone set to: $timezone"
    fi
    
    echo ""
    return 0
}

# Apply changes for XFCE
# Arguments: $1 = timezone, $2 = plugin index, $3 = state dir, $4 = dry run
xfce_apply() {
    local timezone="$1"
    local plugin_index="$2"
    local state_dir="$3"
    local dry_run="${4:-false}"
    
    if ! check_xfconf_available; then
        echo "ERROR: xfconf-query not available" >&2
        return 1
    fi
    
    local plugins
    plugins=$(find_xfce_clock_plugins) || {
        echo "ERROR: No clock plugins found" >&2
        return 1
    }
    
    local plugin_array=()
    while IFS= read -r plugin; do
        [[ -n "$plugin" ]] && plugin_array+=("$plugin")
    done <<< "$plugins"
    
    if [[ "$plugin_index" -lt 1 ]] || [[ "$plugin_index" -gt ${#plugin_array[@]} ]]; then
        echo "ERROR: Invalid plugin index: $plugin_index" >&2
        return 1
    fi
    
    local target="${plugin_array[$((plugin_index - 1))]}"
    local channel="xfce4-panel"
    
    # Read current value
    local current_value
    current_value=$(read_xfconf_value "$channel" "${target}/Timezone") || current_value=""
    
    if [[ "$current_value" == "$timezone" ]]; then
        echo "Already configured correctly. No changes needed."
        return 0
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        echo "DRY RUN: Would set timezone = $timezone in $target"
        echo "DRY RUN: Current value: $current_value"
        return 0
    fi
    
    local manifest
    manifest=$(init_manifest "$state_dir" "xfce" "" \
        "${DETECTED_SESSION_TYPE:-}" "$timezone" "xfconf")
    
    add_manifest_change "$manifest" "property" \
        "${channel}:${target}/Timezone" \
        "$current_value" "$timezone" ""
    
    if ! write_xfconf_value "$channel" "${target}/Timezone" "$timezone"; then
        echo "ERROR: Failed to set timezone" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    fi
    
    local actual
    actual=$(read_xfconf_value "$channel" "${target}/Timezone") || {
        echo "ERROR: Verification failed" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    }
    
    if [[ "$actual" != "$timezone" ]]; then
        echo "ERROR: Verification failed - value mismatch" >&2
        finalize_manifest "$manifest" "failed" "false" "false"
        return 1
    fi
    
    finalize_manifest "$manifest" "success" "true" "false"
    
    echo "Successfully configured XFCE clock."
    echo "Timezone set to: $timezone"
    echo ""
    echo "Note: The panel may need to be restarted for the change to become visible."
    
    return 0
}

# Verify XFCE configuration
xfce_verify() {
    local expected_tz="$1"
    
    if ! check_xfconf_available; then
        return 1
    fi
    
    local plugins
    plugins=$(find_xfce_clock_plugins) || return 1
    
    local channel="xfce4-panel"
    
    while IFS= read -r plugin; do
        [[ -z "$plugin" ]] && continue
        local actual
        actual=$(read_xfconf_value "$channel" "${plugin}/Timezone") || continue
        if [[ "$actual" != "$expected_tz" ]]; then
            return 1
        fi
    done <<< "$plugins"
    
    return 0
}

# Restore XFCE configuration from manifest
xfce_restore() {
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
    if change.get('type') == 'property':
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
        
        local channel property
        IFS=':' read -r channel property <<< "$target"
        
        if write_xfconf_value "$channel" "$property" "$original_value"; then
            echo "Restored $channel $property to $original_value"
        else
            echo "WARNING: Failed to restore $target"
        fi
    done <<< "$changes"
    
    echo "Restoration complete."
    return 0
}

# Show status of XFCE configuration
xfce_status() {
    xfce_inspect
}
