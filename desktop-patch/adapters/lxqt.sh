#!/usr/bin/env bash
# LXQt adapter for desktop-patch
# Handles LXQt panel clock configuration

set -euo pipefail

# LXQt adapter metadata
LXQT_ADAPTER_NAME="lxqt"
LXQT_ADAPTER_DISPLAY="LXQt"
LXQT_ADAPTER_BACKEND="lxqt"

# Detect LXQt environment
lxqt_detect() {
    local xdg_current="${XDG_CURRENT_DESKTOP:-}"
    local xdg_session="${XDG_SESSION_DESKTOP:-}"
    local desktop_session="${DESKTOP_SESSION:-}"
    
    xdg_current="${xdg_current,,}"
    xdg_session="${xdg_session,,}"
    desktop_session="${desktop_session,,}"
    
    if [[ "$xdg_current" == *"lxqt"* ]] || [[ "$xdg_session" == *"lxqt"* ]] || \
       [[ "$desktop_session" == *"lxqt"* ]]; then
        return 0
    fi
    return 1
}

# Inspect LXQt clock configuration
lxqt_inspect() {
    echo "LXQt Clock Configuration:"
    echo ""
    
    local config_file
    config_file=$(find_lxqt_panel_config) || {
        echo "  No LXQt panel configuration file found."
        return 1
    }
    
    echo "Configuration file: $config_file"
    echo ""
    echo "Clock widgets found:"
    
    local widgets
    widgets=$(find_lxqt_clock_widgets "$config_file") || {
        echo "  (none found)"
        return 0
    }
    
    local count=0
    while IFS= read -r widget; do
        [[ -z "$widget" ]] && continue
        count=$((count + 1))
        
        echo ""
        echo "  Widget $count: $widget"
        
        # Parse section:key
        local section="${widget%%:*}"
        local key_prefix="${widget#*:}"
        
        # Try to read timezone setting
        local tz
        tz=$(read_lxqt_value "$config_file" "$section" "timezone") || tz="(not set)"
        echo "    timezone: $tz"
        
    done <<< "$widgets"
    
    if [[ "$count" -eq 0 ]]; then
        echo "  (none found)"
    fi
    
    echo ""
    return 0
}

# Plan changes for LXQt
# Arguments: $1 = selected timezone, $2 = widget index (optional)
lxqt_plan() {
    local timezone="$1"
    local widget_index="${2:-}"
    
    local config_file
    config_file=$(find_lxqt_panel_config) || {
        echo "ERROR: No LXQt panel configuration file found" >&2
        return 1
    }
    
    local widgets
    widgets=$(find_lxqt_clock_widgets "$config_file") || {
        echo "ERROR: No clock widgets found" >&2
        return 1
    }
    
    local widget_array=()
    while IFS= read -r widget; do
        [[ -n "$widget" ]] && widget_array+=("$widget")
    done <<< "$widgets"
    
    if [[ ${#widget_array[@]} -eq 0 ]]; then
        echo "ERROR: No clock widgets found" >&2
        return 1
    fi
    
    echo "Planned changes for LXQt:"
    echo ""
    echo "Configuration file: $config_file"
    echo "Target timezone: $timezone"
    echo ""
    
    if [[ -n "$widget_index" ]]; then
        if [[ "$widget_index" -lt 1 ]] || [[ "$widget_index" -gt ${#widget_array[@]} ]]; then
            echo "ERROR: Invalid widget index: $widget_index" >&2
            return 1
        fi
        local target="${widget_array[$((widget_index - 1))]}"
        echo "Will modify widget: $target"
        echo "  Setting timezone = $timezone"
    else
        echo "Clock widgets to modify:"
        local i
        for i in $(seq 1 ${#widget_array[@]}); do
            echo "  $i) ${widget_array[$((i - 1))]}"
        done
        echo ""
        echo "Each widget will have its timezone set to: $timezone"
    fi
    
    echo ""
    return 0
}

# Apply changes for LXQt
# Arguments: $1 = timezone, $2 = widget index, $3 = state dir, $4 = dry run
lxqt_apply() {
    local timezone="$1"
    local widget_index="$2"
    local state_dir="$3"
    local dry_run="${4:-false}"
    
    local config_file
    config_file=$(find_lxqt_panel_config) || {
        echo "ERROR: No LXQt panel configuration file found" >&2
        return 1
    }
    
    local widgets
    widgets=$(find_lxqt_clock_widgets "$config_file") || {
        echo "ERROR: No clock widgets found" >&2
        return 1
    }
    
    local widget_array=()
    while IFS= read -r widget; do
        [[ -n "$widget" ]] && widget_array+=("$widget")
    done <<< "$widgets"
    
    if [[ "$widget_index" -lt 1 ]] || [[ "$widget_index" -gt ${#widget_array[@]} ]]; then
        echo "ERROR: Invalid widget index: $widget_index" >&2
        return 1
    fi
    
    local target="${widget_array[$((widget_index - 1))]}"
    local section="${target%%:*}"
    local key_prefix="${target#*:}"
    local key="timezone"
    
    # Read current value
    local current_value
    current_value=$(read_lxqt_value "$config_file" "$section" "$key") || current_value=""
    
    if [[ "$current_value" == "$timezone" ]]; then
        echo "Already configured correctly. No changes needed."
        return 0
    fi
    
    if [[ "$dry_run" == "true" ]]; then
        echo "DRY RUN: Would set timezone = $timezone in $section/$key"
        echo "DRY RUN: Current value: $current_value"
        return 0
    fi
    
    local backup_dir
    backup_dir=$(create_backup_directory "$state_dir" "lxqt")
    
    local backup_path
    backup_path=$(write_lxqt_value "$config_file" "$section" "$key" "$timezone" "$backup_dir") || {
        echo "ERROR: Failed to write configuration" >&2
        return 1
    }
    
    local manifest
    manifest=$(init_manifest "$state_dir" "lxqt" "" \
        "${DETECTED_SESSION_TYPE:-}" "$timezone" "lxqt")
    
    add_manifest_change "$manifest" "file" \
        "${config_file}:${section}:${key}" \
        "$current_value" "$timezone" "$backup_path"
    
    local actual
    actual=$(read_lxqt_value "$config_file" "$section" "$key") || {
        echo "ERROR: Verification failed" >&2
        finalize_manifest "$manifest" "failed" "true" "false"
        return 1
    }
    
    if [[ "$actual" != "$timezone" ]]; then
        echo "ERROR: Verification failed - value mismatch" >&2
        finalize_manifest "$manifest" "failed" "true" "false"
        return 1
    fi
    
    finalize_manifest "$manifest" "success" "true" "false"
    
    echo "Successfully configured LXQt clock."
    echo "Timezone set to: $timezone"
    echo ""
    echo "Note: LXQt panel may need to be restarted for the change to become visible."
    
    return 0
}

# Verify LXQt configuration
lxqt_verify() {
    local expected_tz="$1"
    
    local config_file
    config_file=$(find_lxqt_panel_config) || return 1
    
    local widgets
    widgets=$(find_lxqt_clock_widgets "$config_file") || return 1
    
    while IFS= read -r widget; do
        [[ -z "$widget" ]] && continue
        local section="${widget%%:*}"
        local key_prefix="${widget#*:}"
        local key="timezone"
        
        local actual
        actual=$(read_lxqt_value "$config_file" "$section" "$key") || continue
        if [[ "$actual" != "$expected_tz" ]]; then
            return 1
        fi
    done <<< "$widgets"
    
    return 0
}

# Restore LXQt configuration from manifest
lxqt_restore() {
    local manifest="$1"
    local state_dir="$2"
    
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
    if change.get('type') == 'file':
        print(f\"{change['target']}|{change['original_value']}|{change['backup_path']}\")
" "$manifest" 2>/dev/null) || {
        echo "ERROR: Failed to read manifest" >&2
        return 1
    }
    
    if [[ -z "$changes" ]]; then
        echo "No changes to restore."
        return 0
    fi
    
    while IFS='|' read -r target original_value backup_path; do
        [[ -z "$target" ]] && continue
        
        local file section key
        IFS=':' read -r file section key <<< "$target"
        
        if [[ ! -f "$file" ]]; then
            echo "WARNING: Config file not found: $file"
            continue
        fi
        
        if [[ -n "$backup_path" ]] && [[ -f "$backup_path" ]]; then
            cp "$backup_path" "$file"
            echo "Restored from backup: $backup_path"
        else
            local backup_dir="${state_dir}/restore-backup-$(date +%s)"
            mkdir -p "$backup_dir"
            write_lxqt_value "$file" "$section" "$key" "$original_value" "$backup_dir" >/dev/null || {
                echo "WARNING: Failed to restore $target"
                continue
            }
            echo "Restored value for $target"
        fi
    done <<< "$changes"
    
    echo "Restoration complete."
    return 0
}

# Show status of LXQt configuration
lxqt_status() {
    lxqt_inspect
}
