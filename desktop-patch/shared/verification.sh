#!/usr/bin/env bash
# Verification utilities for desktop-patch
# Verifies that changes were applied correctly

set -euo pipefail

# Verify a file was changed correctly
# Arguments: $1 = file path, $2 = expected content pattern (grep -F)
# Returns: 0 if verified, 1 if not
verify_file_content() {
    local file="$1"
    local expected_pattern="$2"
    
    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file" >&2
        return 1
    fi
    
    if grep -qF "$expected_pattern" "$file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Verify a gsettings key has the expected value
# Arguments: $1 = schema, $2 = key, $3 = expected value
# Returns: 0 if verified, 1 if not
verify_gsettings_value() {
    local schema="$1"
    local key="$2"
    local expected="$3"
    
    if ! command -v gsettings &>/dev/null; then
        echo "ERROR: gsettings not available" >&2
        return 1
    fi
    
    local actual
    actual=$(gsettings get "$schema" "$key" 2>/dev/null) || return 1
    
    # Normalize whitespace for comparison
    actual=$(echo "$actual" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    expected=$(echo "$expected" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    
    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify a xfconf key has the expected value
# Arguments: $1 = channel, $2 = property, $3 = expected value
# Returns: 0 if verified, 1 if not
verify_xfconf_value() {
    local channel="$1"
    local property="$2"
    local expected="$3"
    
    if ! command -v xfconf-query &>/dev/null; then
        echo "ERROR: xfconf-query not available" >&2
        return 1
    fi
    
    local actual
    actual=$(xfconf-query -c "$channel" -p "$property" 2>/dev/null) || return 1
    
    # Normalize whitespace for comparison
    actual=$(echo "$actual" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    expected=$(echo "$expected" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    
    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify file integrity (unchanged except for targeted modifications)
# Arguments: $1 = original file, $2 = modified file, $3 = expected diff pattern
# Returns: 0 if only expected changes, 1 if unexpected changes
verify_file_integrity() {
    local original="$1"
    local modified="$2"
    local expected_pattern="$3"
    
    if [[ ! -f "$original" ]] || [[ ! -f "$modified" ]]; then
        echo "ERROR: File not found" >&2
        return 1
    fi
    
    # Get the diff
    local diff_output
    diff_output=$(diff -u "$original" "$modified" 2>/dev/null || true)
    
    # Check that the expected pattern is in the diff
    if ! echo "$diff_output" | grep -qF "$expected_pattern"; then
        return 1
    fi
    
    return 0
}
