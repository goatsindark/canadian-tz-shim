#!/usr/bin/env bash
# Backup management for desktop-patch
# Creates and manages backups of configuration files

set -euo pipefail

# Create a backup of a file
# Arguments: $1 = file path, $2 = backup directory
# Returns: path to backup file on stdout
backup_file() {
    local file="$1"
    local backup_dir="$2"
    
    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file" >&2
        return 1
    fi
    
    mkdir -p "$backup_dir"
    
    # Create backup with timestamp
    local basename
    basename=$(basename "$file")
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="${backup_dir}/${basename}.${timestamp}.bak"
    
    # Ensure unique name
    local counter=0
    while [[ -f "$backup_path" ]]; do
        counter=$((counter + 1))
        backup_path="${backup_dir}/${basename}.${timestamp}.${counter}.bak"
    done
    
    cp -p "$file" "$backup_path"
    
    # Verify backup integrity
    if ! cmp -s "$file" "$backup_path"; then
        echo "ERROR: Backup verification failed for $file" >&2
        rm -f "$backup_path"
        return 1
    fi
    
    echo "$backup_path"
}

# Create a backup directory for a desktop operation
# Arguments: $1 = state directory, $2 = desktop name
# Returns: path to backup directory on stdout
create_backup_directory() {
    local state_dir="$1"
    local desktop="$2"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    
    local backup_dir="${state_dir}/backups/${desktop}-${timestamp}"
    mkdir -p "$backup_dir"
    
    echo "$backup_dir"
}
