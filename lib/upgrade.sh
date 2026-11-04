#!/usr/bin/env bash
# Canadian Timezone Shim - Upgrade Library
# Handles version-aware upgrades with safety guarantees

set -euo pipefail

# Upgrade states
UPGRADE_STATE_CURRENT="current"
UPGRADE_STATE_UPGRADE_AVAILABLE="upgrade_available"
UPGRADE_STATE_REPAIR_REQUIRED="repair_required"
UPGRADE_STATE_UNSUPPORTED="unsupported"
UPGRADE_STATE_NOT_INSTALLED="not_installed"
UPGRADE_STATE_AMBIGUOUS="ambiguous"

# Lock file for concurrent operation protection
UPGRADE_LOCK_FILE="/tmp/canadian-tz-shim-upgrade.lock"

# Global state variables (initialized by discover_installation)
INSTALLED_VERSION=""
SCHEMA_VERSION=""
INSTALLATION_MODE=""
SELECTED_ZONE=""
ORIGINAL_TIMEZONE=""
ORIGINAL_TIMEZONE_PATH=""
INSTALLATION_HEALTHY=false
MANAGED_FILES=()
MISSING_FILES=()
CORRUPTED_FILES=()
UPGRADE_STATE=""
UPGRADE_PATH=""

# Color codes (if not already defined)
if [[ -z "${RED:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

# Logging functions (define unconditionally to override any system commands)
info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ============================================================================
# Installation Discovery
# ============================================================================

# Discover existing installation and return structured information
# Sets global variables: INSTALLED_VERSION, SCHEMA_VERSION, INSTALLATION_MODE, etc.
discover_installation() {
    local system_wide="$1"
    local zoneinfo_dir="$2"
    local state_dir="$3"
    local config_path="$4"
    
    # Reset discovery variables
    INSTALLED_VERSION=""
    SCHEMA_VERSION=""
    INSTALLATION_MODE=""
    SELECTED_ZONE=""
    ORIGINAL_TIMEZONE=""
    ORIGINAL_TIMEZONE_PATH=""
    INSTALLATION_HEALTHY=false
    MANAGED_FILES=()
    MISSING_FILES=()
    CORRUPTED_FILES=()
    
    # Check if config file exists
    if [[ ! -f "$config_path" ]]; then
        # Check for legacy config locations
        if [[ "$system_wide" == "true" && -f "/etc/tzshim.conf" ]]; then
            config_path="/etc/tzshim.conf"
        elif [[ "$system_wide" == "false" && -f "${HOME}/.config/tzshim.conf" ]]; then
            config_path="${HOME}/.config/tzshim.conf"
        else
            # No config found - not installed
            return 0
        fi
    fi
    
    # Source configuration
    source "$config_path"
    
    # Extract version information
    INSTALLED_VERSION="${installed_version:-}"
    SCHEMA_VERSION="${schema_version:-}"
    ORIGINAL_TIMEZONE="${original_timezone:-}"
    ORIGINAL_TIMEZONE_PATH="${original_timezone_path:-}"
    
    # Handle legacy field names (v0.8.x used original_tz instead of original_timezone)
    if [[ -z "$ORIGINAL_TIMEZONE" && -n "${original_tz:-}" ]]; then
        ORIGINAL_TIMEZONE="${original_tz}"
    fi
    
    # Determine installation mode
    if [[ "$system_wide" == "true" ]]; then
        INSTALLATION_MODE="system"
    else
        INSTALLATION_MODE="user"
    fi
    
    # Check for selected zone
    if [[ -f "${state_dir}/selected-zone" ]]; then
        SELECTED_ZONE=$(cat "${state_dir}/selected-zone")
    fi
    
    # Discover managed files
    discover_managed_files "$zoneinfo_dir"
    
    # Validate installation health
    validate_installation_health "$zoneinfo_dir" "$config_path"
    
    return 0
}

# Discover all managed files and check their status
discover_managed_files() {
    local zoneinfo_dir="$1"
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"
    local config_file="${script_dir}/zones.conf"
    
    MANAGED_FILES=()
    MISSING_FILES=()
    CORRUPTED_FILES=()
    
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi
    
    # NOTE: use explicit `if` blocks, never `[[ … ]] && continue`. A failing test
    # in an AND-OR list returns non-zero, which under `set -e` aborts the enclosing
    # function and silently leaves MANAGED_FILES empty.
    while IFS='|' read -r iana_zone _rest; do
        if [[ "$iana_zone" =~ ^#.*$ ]]; then continue; fi
        if [[ -z "$iana_zone" ]]; then continue; fi

        local target_file="${zoneinfo_dir}/${iana_zone}"
        MANAGED_FILES+=("$target_file")

        if [[ ! -f "$target_file" ]]; then
            MISSING_FILES+=("$target_file")
        elif ! validate_tzif_file "$target_file"; then
            CORRUPTED_FILES+=("$target_file")
        fi
    done < "$config_file"
}

# Validate overall installation health
validate_installation_health() {
    local zoneinfo_dir="$1"
    local config_path="$2"
    
    INSTALLATION_HEALTHY=false
    
    # For legacy installations without version info, use different health criteria
    if [[ -z "$INSTALLED_VERSION" ]]; then
        # Legacy installation - check basic health indicators
        # Restoration metadata matters only for system-wide installs
        if [[ "$INSTALLATION_MODE" == "system" ]]; then
            if [[ -z "$ORIGINAL_TIMEZONE" && -z "$ORIGINAL_TIMEZONE_PATH" ]]; then
                return 0
            fi
        fi
        
        # Must have selected zone (for system-wide)
        if [[ "$INSTALLATION_MODE" == "system" && -z "$SELECTED_ZONE" ]]; then
            return 0
        fi
        
        # Check if all managed files exist and are valid
        if [[ ${#MISSING_FILES[@]} -gt 0 ]] || [[ ${#CORRUPTED_FILES[@]} -gt 0 ]]; then
            return 0
        fi
        
        # Legacy installation is healthy if all files are present and valid
        INSTALLATION_HEALTHY=true
        return 0
    fi
    
    # For versioned installations, use full health check
    # Check if schema version is present
    if [[ -z "$SCHEMA_VERSION" ]]; then
        return 0
    fi
    
    # File integrity is required for every mode
    if [[ ${#MISSING_FILES[@]} -gt 0 ]] || [[ ${#CORRUPTED_FILES[@]} -gt 0 ]]; then
        return 0
    fi
    
    # Selected zone is only meaningful for system-wide installs (drives the symlink)
    if [[ "$INSTALLATION_MODE" == "system" && -z "$SELECTED_ZONE" ]]; then
        return 0
    fi
    
    # Restoration metadata is only required for system-wide installs, because only
    # those modify /etc/localtime. A user-level install may legitimately have no
    # original timezone recorded when the pre-existing /etc/localtime pointed into
    # another shim directory (self-referential metadata is deliberately rejected).
    if [[ "$INSTALLATION_MODE" == "system" ]]; then
        if [[ -z "$ORIGINAL_TIMEZONE" && -z "$ORIGINAL_TIMEZONE_PATH" ]]; then
            return 0
        fi
    fi
    
    # All checks passed
    INSTALLATION_HEALTHY=true
}

# ============================================================================
# Upgrade Decision Engine
# ============================================================================

# Determine what action to take based on current state
determine_upgrade_action() {
    local current_release="$1"
    local migrations_file="$2"
    
    UPGRADE_STATE=""
    UPGRADE_PATH=""
    
    # Check if installation exists at all
    # An installation exists if we have config OR timezone files
    local has_config=false
    local has_files=false
    
    if [[ ${#MANAGED_FILES[@]} -gt 0 ]]; then
        # Check if at least one managed file exists
        for file in "${MANAGED_FILES[@]}"; do
            if [[ -f "$file" ]]; then
                has_files=true
                break
            fi
        done
    fi
    
    # Check if config exists (even without version info)
    if [[ -n "$ORIGINAL_TIMEZONE" || -n "$ORIGINAL_TIMEZONE_PATH" || -n "$SELECTED_ZONE" ]]; then
        has_config=true
    fi
    
    # Not installed at all
    if [[ "$has_config" == "false" && "$has_files" == "false" ]]; then
        UPGRADE_STATE="$UPGRADE_STATE_NOT_INSTALLED"
        return 0
    fi
    
    # Installation exists but has no version information (legacy)
    if [[ -z "$INSTALLED_VERSION" ]]; then
        # This is a legacy installation without version tracking
        # Check if it's healthy
        if [[ "$INSTALLATION_HEALTHY" == "true" ]]; then
            # Legacy but healthy - treat as upgradeable from earliest supported version
            local min_version
            min_version=$(python3 -c "
import json
with open('$migrations_file', 'r') as f:
    data = json.load(f)
print(data.get('minimum_version', '0.8.0'))
" 2>/dev/null || echo "0.8.0")
            
            # Check if upgrade path exists from minimum version
            if find_upgrade_path "$min_version" "$current_release" "$migrations_file"; then
                UPGRADE_STATE="$UPGRADE_STATE_UPGRADE_AVAILABLE"
                # Set INSTALLED_VERSION to minimum for migration purposes
                INSTALLED_VERSION="$min_version"
            else
                UPGRADE_STATE="$UPGRADE_STATE_UNSUPPORTED"
            fi
        else
            # Legacy and unhealthy
            UPGRADE_STATE="$UPGRADE_STATE_REPAIR_REQUIRED"
        fi
        return 0
    fi
    
    # Ambiguous - has version but no schema version
    if [[ -z "$SCHEMA_VERSION" ]]; then
        UPGRADE_STATE="$UPGRADE_STATE_AMBIGUOUS"
        return 0
    fi
    
    # Check if version matches current release
    if [[ "$INSTALLED_VERSION" == "$current_release" ]]; then
        # Version matches, but check health
        if [[ "$INSTALLATION_HEALTHY" == "true" ]]; then
            UPGRADE_STATE="$UPGRADE_STATE_CURRENT"
        else
            UPGRADE_STATE="$UPGRADE_STATE_REPAIR_REQUIRED"
        fi
        return 0
    fi
    
    # Check if upgrade path exists
    if find_upgrade_path "$INSTALLED_VERSION" "$current_release" "$migrations_file"; then
        UPGRADE_STATE="$UPGRADE_STATE_UPGRADE_AVAILABLE"
    else
        UPGRADE_STATE="$UPGRADE_STATE_UNSUPPORTED"
    fi
}

# Find a valid upgrade path between versions
find_upgrade_path() {
    local from_version="$1"
    local to_version="$2"
    local migrations_file="$3"
    
    UPGRADE_PATH=""
    
    if [[ ! -f "$migrations_file" ]]; then
        return 1
    fi
    
    # Parse migrations.json to find path
    # Using python for JSON parsing
    local path
    path=$(python3 -c "
import json
import sys

with open('$migrations_file', 'r') as f:
    data = json.load(f)

from_ver = '$from_version'
to_ver = '$to_version'

# Find direct migration
for migration in data.get('migrations', []):
    if migration.get('from_version') == from_ver and migration.get('to_version') == to_ver:
        print(json.dumps(migration))
        sys.exit(0)

# No direct path found
sys.exit(1)
" 2>/dev/null) || return 1
    
    UPGRADE_PATH="$path"
    return 0
}

# ============================================================================
# Locking and Concurrent Operation Protection
# ============================================================================

# Acquire upgrade lock
acquire_upgrade_lock() {
    if [[ -f "$UPGRADE_LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$UPGRADE_LOCK_FILE" 2>/dev/null || echo "")
        
        # Check if process is still running
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            error "Another upgrade operation is in progress (PID: $lock_pid)"
            return 1
        else
            # Stale lock file
            warn "Removing stale lock file"
            rm -f "$UPGRADE_LOCK_FILE"
        fi
    fi
    
    # Create lock file
    echo $$ > "$UPGRADE_LOCK_FILE"
    return 0
}

# Release upgrade lock
release_upgrade_lock() {
    rm -f "$UPGRADE_LOCK_FILE"
}

# ============================================================================
# Migration Execution
# ============================================================================

# Execute upgrade with safety guarantees
execute_upgrade() {
    local dry_run="$1"
    local zoneinfo_dir="$2"
    local state_dir="$3"
    local config_path="$4"
    local migrations_file="$5"
    
    if [[ -z "$UPGRADE_PATH" ]]; then
        error "No upgrade path available"
        return 1
    fi
    
    # Parse upgrade path
    local operations
    operations=$(echo "$UPGRADE_PATH" | python3 -c "
import json
import sys
data = json.load(sys.stdin)
for op in data.get('operations', []):
    print(op['type'])
" 2>/dev/null) || return 1
    
    if [[ "$dry_run" == "true" ]]; then
        # Dry run - just report what would be done
        info "Dry run mode - no changes will be made"
        echo ""
        echo "Planned operations:"
        while IFS= read -r op; do
            echo "  - $op"
        done <<< "$operations"
        return 0
    fi
    
    # Acquire lock
    if ! acquire_upgrade_lock; then
        return 1
    fi
    
    # NOTE: intentionally not installing an EXIT trap here. `trap ... EXIT` inside
    # a library function would silently replace the caller's own EXIT trap (for
    # example a test suite's cleanup handler). Every return path below releases
    # the lock explicitly instead.
    
    # Create backup for rollback
    local backup_dir
    backup_dir=$(create_upgrade_backup "$zoneinfo_dir" "$config_path" "$state_dir")
    if [[ -z "$backup_dir" ]]; then
        error "Failed to create backup"
        release_upgrade_lock
        return 1
    fi
    
    # Execute operations
    local success=true
    while IFS= read -r op; do
        if ! execute_migration_operation "$op" "$zoneinfo_dir" "$state_dir" "$config_path"; then
            error "Migration operation failed: $op"
            success=false
            break
        fi
    done <<< "$operations"
    
    # Validate result
    if [[ "$success" == "true" ]]; then
        if ! validate_post_upgrade "$zoneinfo_dir" "$config_path" "$state_dir"; then
            error "Post-upgrade validation failed"
            success=false
        fi
    fi
    
    # Rollback if failed
    if [[ "$success" == "false" ]]; then
        error "Upgrade failed, initiating rollback..."
        if restore_upgrade_backup "$backup_dir" "$zoneinfo_dir" "$config_path" "$state_dir"; then
            info "Rollback successful"
            # Rollback completed; the backup is no longer needed
            rm -rf -- "$backup_dir"
        else
            error "Rollback failed - manual intervention required"
            error "Backup location: $backup_dir"
        fi
        release_upgrade_lock
        return 1
    fi
    
    # Update version metadata
    # Extract target version from upgrade path
    local target_version
    target_version=$(echo "$UPGRADE_PATH" | python3 -c "
import json
import sys
data = json.load(sys.stdin)
print(data.get('to_version', '1.0.0'))
" 2>/dev/null || echo "1.0.0")
    update_version_metadata "$config_path" "$target_version"
    
    # Clean up backup
    rm -rf "$backup_dir"
    
    release_upgrade_lock
    return 0
}

# Create backup for rollback
create_upgrade_backup() {
    local zoneinfo_dir="$1"
    local config_path="$2"
    local state_dir="$3"
    
    local backup_dir
    backup_dir=$(mktemp -d "/tmp/canadian-tz-shim-backup.XXXXXX")
    
    # Backup configuration
    if [[ -f "$config_path" ]]; then
        cp "$config_path" "${backup_dir}/config"
    fi
    
    # Backup state
    if [[ -d "$state_dir" ]]; then
        cp -r "$state_dir" "${backup_dir}/state"
    fi
    
    # Backup timezone files - preserve relative path structure
    for file in "${MANAGED_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            # Get relative path from zoneinfo_dir
            local rel_path="${file#$zoneinfo_dir/}"
            local backup_path="${backup_dir}/zoneinfo/${rel_path}"
            local backup_dir_path
            backup_dir_path=$(dirname "$backup_path")
            
            # Create parent directories
            mkdir -p "$backup_dir_path"
            
            # Copy file
            cp "$file" "$backup_path"
        fi
    done
    
    echo "$backup_dir"
}

# Restore from backup
restore_upgrade_backup() {
    local backup_dir="$1"
    local zoneinfo_dir="$2"
    local config_path="$3"
    local state_dir="$4"
    
    # Restore configuration
    if [[ -f "${backup_dir}/config" ]]; then
        cp "${backup_dir}/config" "$config_path"
    fi
    
    # Restore state
    if [[ -d "${backup_dir}/state" ]]; then
        rm -rf "$state_dir"
        cp -r "${backup_dir}/state" "$state_dir"
    fi
    
    # Restore timezone files - preserve relative path structure
    if [[ -d "${backup_dir}/zoneinfo" ]]; then
        # Find all files in backup and restore them to their relative positions
        while IFS= read -r -d '' backup_file; do
            # Get relative path from backup zoneinfo dir
            local rel_path="${backup_file#${backup_dir}/zoneinfo/}"
            local restore_path="${zoneinfo_dir}/${rel_path}"
            local restore_dir_path
            restore_dir_path=$(dirname "$restore_path")
            
            # Create parent directories if needed
            mkdir -p "$restore_dir_path"
            
            # Copy file back
            cp "$backup_file" "$restore_path"
        done < <(find "${backup_dir}/zoneinfo" -type f -print0)
    fi
    
    return 0
}

# Derive install mode from a zoneinfo target directory.
# Self-contained so library functions never depend on unset globals.
_derive_install_mode() {
    local zoneinfo_dir="$1"
    case "$zoneinfo_dir" in
        /usr/local/share/zoneinfo*) echo "system" ;;
        *) echo "user" ;;
    esac
}

# Execute a single migration operation
execute_migration_operation() {
    local operation="$1"
    local zoneinfo_dir="$2"
    local state_dir="$3"
    local config_path="$4"
    
    case "$operation" in
        backup_metadata)
            # Already done in create_upgrade_backup
            return 0
            ;;
        migrate_config)
            # Migrate configuration format
            if [[ -f "$config_path" ]]; then
                # Handle field renames
                if grep -q "original_tz=" "$config_path" 2>/dev/null; then
                    sed -i 's/original_tz=/original_timezone=/g' "$config_path"
                fi
            fi
            return 0
            ;;
        update_scripts)
            # Update library scripts and patcher.
            # Derive install mode from the target zoneinfo dir so this operation
            # does not depend on globals that may be unset in library context.
            if [[ ! -n "${SCRIPT_DIR:-}" ]]; then
                error "SCRIPT_DIR is not set; cannot locate source scripts"
                return 1
            fi
            local source_dir="${SCRIPT_DIR}"
            local upgrade_mode
            upgrade_mode=$(_derive_install_mode "$zoneinfo_dir")

            local target_lib_dir target_config_dir
            if [[ "$upgrade_mode" == "system" ]]; then
                target_lib_dir="/usr/local/libexec/canadian-tz-shim"
                target_config_dir="/usr/local/share/canadian-tz-shim"
            else
                target_lib_dir="${HOME:-/tmp}/.local/lib/canadian-tz-shim"
                target_config_dir="${HOME:-/tmp}/.local/share/canadian-tz-shim"
            fi

            mkdir -p "$target_lib_dir"

            # Update patch_tzif.py
            if [[ -f "${source_dir}/lib/patch_tzif.py" ]]; then
                cp "${source_dir}/lib/patch_tzif.py" "${target_lib_dir}/patch_tzif.py"
                chmod +x "${target_lib_dir}/patch_tzif.py"
            else
                error "Source patch_tzif.py not found"
                return 1
            fi

            # Update reapply.sh
            if [[ -f "${source_dir}/lib/reapply.sh" ]]; then
                cp "${source_dir}/lib/reapply.sh" "${target_lib_dir}/reapply.sh"
                chmod +x "${target_lib_dir}/reapply.sh"
            else
                error "Source reapply.sh not found"
                return 1
            fi

            # Update upgrade library itself
            if [[ -f "${source_dir}/lib/upgrade.sh" ]]; then
                cp "${source_dir}/lib/upgrade.sh" "${target_lib_dir}/upgrade.sh"
            fi

            # Update zones.conf
            if [[ -f "${source_dir}/zones.conf" ]]; then
                mkdir -p "$target_config_dir"
                cp "${source_dir}/zones.conf" "${target_config_dir}/zones.conf"
            else
                error "Source zones.conf not found"
                return 1
            fi

            return 0
            ;;
        install_systemd)
            # Install systemd service units (system-wide only)
            local upgrade_mode
            upgrade_mode=$(_derive_install_mode "$zoneinfo_dir")
            if [[ "$upgrade_mode" != "system" ]]; then
                # Skip systemd installation for user-level installs
                return 0
            fi

            local source_dir="${SCRIPT_DIR:-}"
            
            # Check if systemd is available
            if ! command -v systemctl &>/dev/null; then
                warn "systemctl not available, skipping systemd installation"
                return 0
            fi
            
            # Install service units
            if [[ -f "${source_dir}/lib/canadian-tz-shim.service" ]]; then
                cp "${source_dir}/lib/canadian-tz-shim.service" /etc/systemd/system/
            else
                error "canadian-tz-shim.service not found"
                return 1
            fi
            
            if [[ -f "${source_dir}/lib/canadian-tz-shim.path" ]]; then
                cp "${source_dir}/lib/canadian-tz-shim.path" /etc/systemd/system/
            else
                error "canadian-tz-shim.path not found"
                return 1
            fi
            
            # Reload systemd
            systemctl daemon-reload 2>/dev/null || true
            
            # Enable and start the path unit
            systemctl enable canadian-tz-shim.path 2>/dev/null || true
            systemctl restart canadian-tz-shim.path 2>/dev/null || true
            
            return 0
            ;;
        update_metadata)
            # Will be done in update_version_metadata
            return 0
            ;;
        validate_installation)
            # Validate all timezone files
            for file in "${MANAGED_FILES[@]}"; do
                if [[ -f "$file" ]]; then
                    if ! zdump -v "$file" &>/dev/null; then
                        return 1
                    fi
                fi
            done
            return 0
            ;;
        *)
            warn "Unknown operation: $operation"
            return 0
            ;;
    esac
}

# Validate installation after upgrade
validate_post_upgrade() {
    local zoneinfo_dir="$1"
    local config_path="$2"
    local state_dir="${3:-}"

    local system_wide="false"
    if [[ "$(_derive_install_mode "$zoneinfo_dir")" == "system" ]]; then
        system_wide="true"
    fi

    if [[ -z "$state_dir" ]]; then
        if [[ "$system_wide" == "true" ]]; then
            state_dir="/var/lib/canadian-tz-shim"
        else
            state_dir="${HOME:-/tmp}/.local/state/canadian-tz-shim"
        fi
    fi

    discover_installation "$system_wide" "$zoneinfo_dir" "$state_dir" "$config_path"

    if [[ "$INSTALLATION_HEALTHY" != "true" ]]; then
        return 1
    fi

    for file in "${MANAGED_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            if ! validate_tzif_file "$file"; then
                return 1
            fi
        fi
    done

    return 0
}

# Update version metadata after successful upgrade
update_version_metadata() {
    local config_path="$1"
    local current_release="$2"
    
    if [[ ! -f "$config_path" ]]; then
        return 0
    fi
    
    # Update or add version fields
    if grep -q "^installed_version=" "$config_path" 2>/dev/null; then
        sed -i "s/^installed_version=.*/installed_version=${current_release}/" "$config_path"
    else
        echo "installed_version=${current_release}" >> "$config_path"
    fi
    
    if grep -q "^schema_version=" "$config_path" 2>/dev/null; then
        sed -i "s/^schema_version=.*/schema_version=1/" "$config_path"
    else
        echo "schema_version=1" >> "$config_path"
    fi
}

# ============================================================================
# Reporting
# ============================================================================

# Report installation discovery results
report_installation_status() {
    echo "Installation Discovery Results:"
    echo "================================"
    echo ""

    # Distinguish "nothing installed" from "installed by a pre-versioning release".
    local has_files=false
    local f
    for f in "${MANAGED_FILES[@]:-}"; do
        if [[ -n "$f" && -f "$f" ]]; then has_files=true; break; fi
    done

    if [[ -z "$INSTALLED_VERSION" ]]; then
        if [[ "$has_files" == "true" ]]; then
            echo "Status: Legacy installation (managed files present, no version metadata)"
            echo "Installed version: (not recorded by older release)"
        else
            echo "Status: Not installed"
            return 0
        fi
    else
        echo "Installed version: ${INSTALLED_VERSION}"
    fi

    echo "Schema version: ${SCHEMA_VERSION:-unknown}"
    echo "Installation mode: ${INSTALLATION_MODE:-unknown}"
    echo "Selected zone: ${SELECTED_ZONE:-none}"
    echo "Original timezone: ${ORIGINAL_TIMEZONE:-${ORIGINAL_TIMEZONE_PATH:-unknown}}"
    echo "Installation healthy: ${INSTALLATION_HEALTHY}"
    echo ""
    echo "Managed files: ${#MANAGED_FILES[@]}"
    echo "Missing files: ${#MISSING_FILES[@]}"
    echo "Corrupted files: ${#CORRUPTED_FILES[@]}"
    
    if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
        echo ""
        echo "Missing files:"
        for file in "${MISSING_FILES[@]}"; do
            echo "  - $file"
        done
    fi
    
    if [[ ${#CORRUPTED_FILES[@]} -gt 0 ]]; then
        echo ""
        echo "Corrupted files:"
        for file in "${CORRUPTED_FILES[@]}"; do
            echo "  - $file"
        done
    fi
}

# Report upgrade decision
report_upgrade_decision() {
    local current_release="$1"
    
    echo ""
    echo "Upgrade Decision:"
    echo "================="
    echo ""
    echo "Current release: $current_release"
    
    case "$UPGRADE_STATE" in
        "$UPGRADE_STATE_CURRENT")
            echo "Status: Current (no upgrade needed)"
            echo "Installation is healthy and up-to-date."
            ;;
        "$UPGRADE_STATE_UPGRADE_AVAILABLE")
            echo "Status: Upgrade available"
            echo "Upgrade path: ${INSTALLED_VERSION} → ${current_release}"
            ;;
        "$UPGRADE_STATE_REPAIR_REQUIRED")
            echo "Status: Repair required"
            echo "Installation is at current version but has issues."
            ;;
        "$UPGRADE_STATE_UNSUPPORTED")
            echo "Status: Unsupported"
            echo "No upgrade path available from ${INSTALLED_VERSION} to ${current_release}"
            ;;
        "$UPGRADE_STATE_NOT_INSTALLED")
            echo "Status: Not installed"
            echo "No existing installation detected."
            ;;
        "$UPGRADE_STATE_AMBIGUOUS")
            echo "Status: Ambiguous"
            echo "Cannot determine installation state reliably."
            ;;
    esac
}

# ============================================================================
# Repair Functionality
# ============================================================================

# Execute repair operation for installations that are at current version but have issues
execute_repair() {
    local zoneinfo_dir="$1"
    local state_dir="$2"
    local config_path="$3"
    local config_file="${SCRIPT_DIR}/zones.conf"
    
    info "Starting repair operation..."
    
    # Create backup before repair
    local backup_dir
    backup_dir=$(create_upgrade_backup "$zoneinfo_dir" "$config_path" "$state_dir")
    if [[ -z "$backup_dir" ]]; then
        error "Failed to create backup for repair"
        return 1
    fi
    
    local repaired_count=0
    local failed_count=0
    
    # Iterate through all managed zones
    while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
        if [[ "$iana_zone" =~ ^#.*$ ]]; then continue; fi
        if [[ -z "$iana_zone" ]]; then continue; fi

        local system_zone="/usr/share/zoneinfo/${iana_zone}"
        local target_zone="${zoneinfo_dir}/${iana_zone}"
        
        # Check if repair is needed
        local needs_repair=false
        local repair_reason=""
        
        if [[ ! -f "$target_zone" ]]; then
            needs_repair=true
            repair_reason="missing"
        elif ! validate_tzif_file "$target_zone" 2>/dev/null; then
            needs_repair=true
            repair_reason="corrupted"
        else
            # Check if abbreviation is correct
            local verify_year="2026"
            if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
                verify_year="2020"
            fi
            
            local zdump_output
            zdump_output=$(zdump -v "$target_zone" 2>/dev/null) || zdump_output=""
            
            if ! echo "$zdump_output" | grep -q "$verify_year.*$official_abbrev"; then
                needs_repair=true
                repair_reason="incorrect abbreviation"
            fi
        fi
        
        if [[ "$needs_repair" == "false" ]]; then
            continue
        fi
        
        info "Repairing $iana_zone (reason: $repair_reason)"
        
        # Check source file exists
        if [[ ! -f "$system_zone" ]]; then
            error "Source timezone file not found: $system_zone"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Create target directory if needed
        local target_dir
        target_dir=$(dirname "$target_zone")
        mkdir -p "$target_dir"
        
        # Copy fresh from system
        if ! cp "$system_zone" "$target_zone"; then
            error "Failed to copy $system_zone to $target_zone"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Apply TZif patch
        local patch_count
        patch_count=$(python3 "${SCRIPT_DIR}/lib/patch_tzif.py" "$target_zone" "$iana_abbrev" "$official_abbrev" 2>/dev/null) || patch_count=0
        
        if [[ "$patch_count" -le 0 ]]; then
            error "Failed to patch $iana_zone"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Validate the repair
        if ! validate_tzif_file "$target_zone"; then
            error "Validation failed after repair of $iana_zone"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Verify UTC offset
        local expected_offset=""
        case "$official_abbrev" in
            PCT) expected_offset="-0700" ;;
            ABT) expected_offset="-0600" ;;
            YST) expected_offset="-0700" ;;
            MBT) expected_offset="-0500" ;;
            NWT) expected_offset="-0600" ;;
        esac
        
        if [[ -n "$expected_offset" ]]; then
            local test_date="2026-12-15"
            if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
                test_date="2021-06-15"
            fi
            
            local actual_offset
            actual_offset=$(TZ="$target_zone" date -d "$test_date 12:00:00" +"%z" 2>/dev/null || echo "")
            
            if [[ "$actual_offset" != "$expected_offset" ]]; then
                error "UTC offset mismatch after repair of $iana_zone (expected $expected_offset, got $actual_offset)"
                failed_count=$((failed_count + 1))
                continue
            fi
        fi
        
        info "✓ Successfully repaired $iana_zone"
        repaired_count=$((repaired_count + 1))
        
    done < "$config_file"
    
    # Validate entire installation after repair
    info "Validating installation after repair..."
    if ! validate_post_upgrade "$zoneinfo_dir" "$config_path" "$state_dir"; then
        error "Post-repair validation failed, rolling back..."
        if restore_upgrade_backup "$backup_dir" "$zoneinfo_dir" "$config_path" "$state_dir"; then
            info "Rollback successful"
            rm -rf -- "$backup_dir"
        else
            error "Rollback failed - manual intervention required"
            error "Backup location: $backup_dir"
        fi
        return 1
    fi
    
    # Clean up backup
    rm -rf "$backup_dir"
    
    info "Repair complete: $repaired_count repaired, $failed_count failed"
    
    if [[ $failed_count -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# Validate a TZif file for integrity
validate_tzif_file() {
    local file="$1"
    
    # Check file exists
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    # Check file size is reasonable
    local file_size
    file_size=$(stat -c%s "$file" 2>/dev/null || echo 0)
    
    if [[ "$file_size" -lt 100 ]]; then
        # Unreasonably small file
        return 1
    fi
    
    # Check that it has valid TZif magic bytes using hexdump
    local magic
    magic=$(hexdump -C "$file" 2>/dev/null | head -1 | awk '{print $2 $3 $4 $5}' || echo "")
    
    # Valid TZif magic bytes are "TZif" (54 5a 69 66)
    if [[ "$magic" != "545a6966" ]]; then
        # Not a valid TZif file - could be corrupted text or other garbage
        local first_line
        first_line=$(head -1 "$file" 2>/dev/null || echo "")
        if [[ "$first_line" == "corrupted data" ]]; then
            # This is definitely corrupted
            return 1
        fi
        # Also check if it's just plain text
        if [[ "$first_line" != "TZif"* ]] && [[ "$file_size" -lt 1000 ]]; then
            # If it's small and not a proper TZif file, likely corrupted
            return 1
        fi
    fi
    
    # Validate file structure using zdump
    if ! zdump -v "$file" &>/dev/null; then
        # zdump failed, but we should also check for malformed TZif
        return 1
    fi
    
    # Reject non-TZif input using the dedicated, read-only structural validator.
    # This does not write to the file and produces no stdout noise.
    if ! command -v python3 &>/dev/null; then
        # Fail closed: without python3 we cannot perform reliable validation
        return 1
    fi

    local validator="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/patch_tzif.py"
    if [[ ! -f "$validator" ]]; then
        # Fail closed: validator missing means we cannot trust this file
        return 1
    fi

    if ! python3 "$validator" --validate "$file" 2>/dev/null; then
        return 1
    fi

    return 0
}
