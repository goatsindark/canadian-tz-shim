#!/usr/bin/env bash
# LXQt backend
# Handles reading and writing LXQt configuration files safely

set -euo pipefail

# Find the LXQt panel configuration file
# Returns: path to panel config file on stdout
find_lxqt_panel_config() {
    local config_dir="${1:-$HOME/.config/lxqt}"
    
    local panel_conf="${config_dir}/panel.conf"
    
    if [[ -f "$panel_conf" ]]; then
        echo "$panel_conf"
        return 0
    fi
    
    return 1
}

# Find all clock widget sections in an LXQt panel config file.
# Real LXQt format:
#   [panel1]
#   plugins=fancymenu,clock,worldclock,tray
#   ...
#   [clock]                       <- one section per widget
#   type=clock
#   timezone=America/Vancouver
#   ...
#   [worldclock]                  <- also a clock-family widget
#   type=worldclock
#   ...
# We emit one line per widget section that has `type=clock` or
# `type=worldclock`, in the form "<section>:<keyprefix>" for backward
# compat with the rest of the code, but the primary value is the section
# name; consumers read/write directly into that section.
find_lxqt_clock_widgets() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        return 1
    fi

    # Walk sections; remember the current one; when we hit a `type=` line
    # matching clock/worldclock, record the section name.
    local cur=""
    local -a hits=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank
        case "$line" in \#*|"") continue ;; esac
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            cur="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^type=(.+)$ ]] && [[ -n "$cur" ]]; then
            local t="${BASH_REMATCH[1]}"
            case "$t" in
                clock|worldclock)
                    # Only once per section
                    local dup=0
                    for h in "${hits[@]-}"; do [[ "$h" == "$cur" ]] && dup=1 && break; done
                    if [[ "$dup" == "0" ]]; then
                        hits+=("$cur")
                    fi
                    ;;
            esac
        fi
    done < "$config_file"

    # Emit "<section>:<section>" to keep the tuple shape of the old code
    # (section_name:key_prefix). Callers only use section_name.
    for h in "${hits[@]-}"; do printf '%s:%s\n' "$h" "$h"; done
}

# Read a value from an LXQt INI file
# Arguments: $1 = config file, $2 = section, $3 = key
# Returns: value on stdout
read_lxqt_value() {
    local config_file="$1"
    local section="$2"
    local key="$3"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    local in_section=false
    local found=false
    local value=""
    
    while IFS= read -r line; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=true
            else
                if [[ "$in_section" == "true" ]]; then
                    break
                fi
            fi
        elif [[ "$in_section" == "true" ]] && [[ "$line" =~ ^${key}= ]]; then
            value="${line#*=}"
            found=true
            break
        fi
    done < "$config_file"
    
    if [[ "$found" == "true" ]]; then
        echo "$value"
        return 0
    fi
    
    return 1
}

# Write a value to an LXQt INI file atomically
# Arguments: $1 = config file, $2 = section, $3 = key, $4 = value, $5 = backup dir
# Returns: backup path on stdout, 0 on success, 1 on failure
write_lxqt_value() {
    local config_file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local backup_dir="$5"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        return 1
    fi
    
    # Create backup
    local backup_path
    backup_path=$(backup_file "$config_file" "$backup_dir") || return 1
    
    # Create temporary file
    local temp_file="${config_file}.tmp.$$"
    
    # Process the file
    local in_section=false
    local key_found=false
    local section_found=false
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            local current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "$section" ]]; then
                in_section=true
                section_found=true
                echo "$line"
            else
                if [[ "$in_section" == "true" ]] && [[ "$key_found" == "false" ]]; then
                    echo "${key}=${value}"
                    key_found=true
                fi
                in_section=false
                echo "$line"
            fi
        elif [[ "$in_section" == "true" ]] && [[ "$line" =~ ^${key}= ]]; then
            echo "${key}=${value}"
            key_found=true
        else
            echo "$line"
        fi
    done < "$config_file" > "$temp_file"
    
    if [[ "$section_found" == "false" ]]; then
        echo "ERROR: Section not found: $section" >&2
        rm -f "$temp_file"
        return 1
    fi
    
    # Atomic replacement
    if ! mv "$temp_file" "$config_file"; then
        echo "ERROR: Failed to replace config file" >&2
        rm -f "$temp_file"
        return 1
    fi
    
    # Verify the change
    local actual
    actual=$(read_lxqt_value "$config_file" "$section" "$key") || {
        echo "ERROR: Verification failed after write" >&2
        cp "$backup_path" "$config_file"
        return 1
    }
    
    if [[ "$actual" != "$value" ]]; then
        echo "ERROR: Written value does not match expected" >&2
        cp "$backup_path" "$config_file"
        return 1
    fi
    
    echo "$backup_path"
    return 0
}

# Check if LXQt is currently running
# Returns: 0 if running, 1 if not
is_lxqt_running() {
    if pgrep -x lxqt-panel &>/dev/null; then
        return 0
    fi
    return 1
}
