#!/usr/bin/env bash
# KConfig backend for KDE Plasma
# Handles reading and writing KDE configuration files safely

set -euo pipefail

# Find the Plasma configuration file
# Returns: path to appletsrc file on stdout
find_plasma_config() {
    local config_dir="${1:-$HOME/.config}"
    
    # Plasma 5 and 6 use the same config file name
    local appletsrc="${config_dir}/plasma-org.kde.plasma.desktop-appletsrc"
    
    if [[ -f "$appletsrc" ]]; then
        echo "$appletsrc"
        return 0
    fi
    
    return 1
}

# Parse a KConfig file and extract sections
# Arguments: $1 = config file
# Outputs: section names, one per line
list_kconfig_sections() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    grep -E '^\[' "$config_file" | sed 's/^\[//;s/\]$//' | sort -u
}

# Find all clock applet instances in the Plasma config
# Arguments: $1 = config file
# Outputs: section names containing clock applets, one per line
find_clock_applets() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    # Look for sections that contain digital clock or other clock plugins
    # Clock applets typically have plugin=digitalclock or plugin=org.kde.plasma.digitalclock
    local in_section=""
    local has_clock=false
    local sections=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            # Save previous section if it was a clock
            if [[ "$has_clock" == "true" ]] && [[ -n "$in_section" ]]; then
                sections+=("$in_section")
            fi
            in_section="${BASH_REMATCH[1]}"
            has_clock=false
        elif [[ "$line" =~ ^plugin= ]]; then
            local plugin="${line#plugin=}"
            if [[ "$plugin" == *"clock"* ]] || [[ "$plugin" == *"digitalclock"* ]]; then
                has_clock=true
            fi
        fi
    done < "$config_file"
    
    # Check last section
    if [[ "$has_clock" == "true" ]] && [[ -n "$in_section" ]]; then
        sections+=("$in_section")
    fi
    
    # Output unique sections
    printf '%s\n' "${sections[@]}" | sort -u
}

# Read a value from a KConfig section
# Arguments: $1 = config file, $2 = section, $3 = key
# Returns: value on stdout, or empty if not found
read_kconfig_value() {
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

# Write a value to a KConfig section atomically
# Arguments: $1 = config file, $2 = section, $3 = key, $4 = value, $5 = backup dir
# Returns: 0 on success, 1 on failure
write_kconfig_value() {
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
                # If we were in the target section and didn't find the key, add it
                if [[ "$in_section" == "true" ]] && [[ "$key_found" == "false" ]]; then
                    echo "${key}=${value}"
                    key_found=true
                fi
                in_section=false
                echo "$line"
            fi
        elif [[ "$in_section" == "true" ]] && [[ "$line" =~ ^${key}= ]]; then
            # Replace existing key
            echo "${key}=${value}"
            key_found=true
        else
            echo "$line"
        fi
    done < "$config_file" > "$temp_file"
    
    # If section was found but key wasn't, add it at the end of the section
    # (This case is handled above when we exit the section)
    
    # If section wasn't found at all, we can't add it (would require creating a new section)
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
    actual=$(read_kconfig_value "$config_file" "$section" "$key") || {
        echo "ERROR: Verification failed after write" >&2
        # Restore from backup
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

# Check if Plasma is currently running
# Returns: 0 if running, 1 if not
is_plasma_running() {
    if pgrep -x plasmashell &>/dev/null; then
        return 0
    fi
    return 1
}

# Get Plasma version
# Returns: version string on stdout
get_plasma_version() {
    if command -v plasmashell &>/dev/null; then
        plasmashell --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1
    fi
}
