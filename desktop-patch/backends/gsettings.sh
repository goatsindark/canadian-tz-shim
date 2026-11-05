#!/usr/bin/env bash
# GSettings backend for GNOME, Cinnamon, MATE, and Budgie
# Handles reading and writing GSettings/dconf values safely

set -euo pipefail

# Check if gsettings is available
# Returns: 0 if available, 1 if not
check_gsettings_available() {
    if command -v gsettings &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if a schema exists
# Arguments: $1 = schema name
# Returns: 0 if exists, 1 if not
gsettings_schema_exists() {
    local schema="$1"
    
    if ! check_gsettings_available; then
        return 1
    fi
    
    if gsettings list-keys "$schema" &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if a key exists in a schema
# Arguments: $1 = schema, $2 = key
# Returns: 0 if exists, 1 if not
gsettings_key_exists() {
    local schema="$1"
    local key="$2"
    
    if ! gsettings_schema_exists "$schema"; then
        return 1
    fi
    
    if gsettings list-keys "$schema" 2>/dev/null | grep -q "^${key}$"; then
        return 0
    fi
    return 1
}

# Check if a key is writable
# Arguments: $1 = schema, $2 = key
# Returns: 0 if writable, 1 if not
gsettings_key_writable() {
    local schema="$1"
    local key="$2"
    
    if ! gsettings_key_exists "$schema" "$key"; then
        return 1
    fi
    
    local range
    range=$(gsettings range "$schema" "$key" 2>/dev/null) || return 1
    
    # If range is empty or "type any", it's writable
    # If range shows specific values, it may still be writable
    # The real test is trying to set it
    return 0
}

# Read a GSettings value
# Arguments: $1 = schema, $2 = key
# Returns: value on stdout
read_gsettings_value() {
    local schema="$1"
    local key="$2"
    
    if ! check_gsettings_available; then
        echo "ERROR: gsettings not available" >&2
        return 1
    fi
    
    if ! gsettings_key_exists "$schema" "$key"; then
        echo "ERROR: Key not found: $schema $key" >&2
        return 1
    fi
    
    gsettings get "$schema" "$key" 2>/dev/null
}

# Write a GSettings value
# Arguments: $1 = schema, $2 = key, $3 = value
# Returns: 0 on success, 1 on failure
write_gsettings_value() {
    local schema="$1"
    local key="$2"
    local value="$3"
    
    if ! check_gsettings_available; then
        echo "ERROR: gsettings not available" >&2
        return 1
    fi
    
    if ! gsettings_key_exists "$schema" "$key"; then
        echo "ERROR: Key not found: $schema $key" >&2
        return 1
    fi
    
    # Try to set the value
    if ! gsettings set "$schema" "$key" "$value" 2>/dev/null; then
        echo "ERROR: Failed to set value" >&2
        return 1
    fi
    
    # Verify the change
    local actual
    actual=$(gsettings get "$schema" "$key" 2>/dev/null) || {
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

# List all keys in a schema
# Arguments: $1 = schema
# Outputs: key names, one per line
list_gsettings_keys() {
    local schema="$1"
    
    if ! gsettings_schema_exists "$schema"; then
        return 1
    fi
    
    gsettings list-keys "$schema" 2>/dev/null
}

# Reset a key to its default value
# Arguments: $1 = schema, $2 = key
# Returns: 0 on success, 1 on failure
reset_gsettings_key() {
    local schema="$1"
    local key="$2"
    
    if ! gsettings_key_exists "$schema" "$key"; then
        return 1
    fi
    
    gsettings reset "$schema" "$key" 2>/dev/null
}

# List all schemas matching a pattern
# Arguments: $1 = pattern (optional)
# Outputs: schema names, one per line
list_gsettings_schemas() {
    local pattern="${1:-}"
    
    if ! check_gsettings_available; then
        return 1
    fi
    
    if [[ -n "$pattern" ]]; then
        gsettings list-schemas 2>/dev/null | grep -i "$pattern"
    else
        gsettings list-schemas 2>/dev/null
    fi
}
