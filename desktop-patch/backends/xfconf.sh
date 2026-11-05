#!/usr/bin/env bash
# Xfconf backend for XFCE
# Handles reading and writing XFCE configuration via xfconf-query

set -euo pipefail

# Check if xfconf-query is available
# Returns: 0 if available, 1 if not
check_xfconf_available() {
    if command -v xfconf-query &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if a channel exists
# Arguments: $1 = channel name
# Returns: 0 if exists, 1 if not
xfconf_channel_exists() {
    local channel="$1"
    
    if ! check_xfconf_available; then
        return 1
    fi
    
    if xfconf-query -c "$channel" -l &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if a property exists in a channel
# Arguments: $1 = channel, $2 = property path
# Returns: 0 if exists, 1 if not
xfconf_property_exists() {
    local channel="$1"
    local property="$2"
    
    if ! xfconf_channel_exists "$channel"; then
        return 1
    fi
    
    if xfconf-query -c "$channel" -p "$property" &>/dev/null; then
        return 0
    fi
    return 1
}

# Read a xfconf property value
# Arguments: $1 = channel, $2 = property
# Returns: value on stdout
read_xfconf_value() {
    local channel="$1"
    local property="$2"
    
    if ! check_xfconf_available; then
        echo "ERROR: xfconf-query not available" >&2
        return 1
    fi
    
    if ! xfconf_property_exists "$channel" "$property"; then
        echo "ERROR: Property not found: $channel $property" >&2
        return 1
    fi
    
    xfconf-query -c "$channel" -p "$property" 2>/dev/null
}

# Write a xfconf property value
# Arguments: $1 = channel, $2 = property, $3 = value, $4 = type (optional, default string)
# Returns: 0 on success, 1 on failure
write_xfconf_value() {
    local channel="$1"
    local property="$2"
    local value="$3"
    local type="${4:-string}"
    
    if ! check_xfconf_available; then
        echo "ERROR: xfconf-query not available" >&2
        return 1
    fi
    
    # Try to set the value
    if ! xfconf-query -c "$channel" -p "$property" -s "$value" -t "$type" 2>/dev/null; then
        echo "ERROR: Failed to set value" >&2
        return 1
    fi
    
    # Verify the change
    local actual
    actual=$(xfconf-query -c "$channel" -p "$property" 2>/dev/null) || {
        echo "ERROR: Verification failed after write" >&2
        return 1
    }
    
    # Normalize for comparison
    local norm_actual norm_expected
    norm_actual=$(echo "$actual" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    norm_expected=$(echo "$value" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    
    if [[ "$norm_actual" != "$norm_expected" ]]; then
        echo "ERROR: Written value does not match expected" >&2
        return 1
    fi
    
    return 0
}

# List all properties in a channel
# Arguments: $1 = channel
# Outputs: property paths, one per line
list_xfconf_properties() {
    local channel="$1"
    
    if ! xfconf_channel_exists "$channel"; then
        return 1
    fi
    
    xfconf-query -c "$channel" -l 2>/dev/null
}

# Find clock plugin instances in XFCE panels
# Real Xfconf layout: /plugins/plugin-<N> is a string whose value is the
# plugin type (e.g. "clock"). Each plugin's settings live under
# /plugins/plugin-<N>/<Property>. The clock plugin's timezone is stored
# under `Timezone` (capital T) per xfce4-panel's libclock source.
# Output: one line per clock plugin instance, the plugin's own path
# (e.g. /plugins/plugin-3).
find_xfce_clock_plugins() {
    if ! check_xfconf_available; then
        return 1
    fi

    local channel="xfce4-panel"
    if ! xfconf_channel_exists "$channel"; then
        return 1
    fi

    # Enumerate /plugins/plugin-<N> leaves whose value is "clock"
    xfconf-query -c "$channel" -l 2>/dev/null \
        | grep -E '^/plugins/plugin-[0-9]+$' \
        | while read -r prop; do
            local value
            value=$(xfconf-query -c "$channel" -p "$prop" 2>/dev/null) || continue
            if [[ "$value" == "clock" ]]; then
                echo "$prop"
            fi
        done
}

# Canonical XFCE clock-plugin property name for the zone identifier.
# Real xfce4-panel/libclock uses "Timezone" (capital T) for the IANA id
# property. Older/derivative builds may use lowercase; the adapter tries
# both, preferring this one.
XFCE_TZ_PROPERTY="Timezone"

# Get the plugin number from a plugin path
# Arguments: $1 = plugin path (e.g., /plugins/plugin-3)
# Returns: plugin number on stdout
get_xfce_plugin_number() {
    local plugin_path="$1"
    
    echo "$plugin_path" | grep -oE '[0-9]+$'
}
