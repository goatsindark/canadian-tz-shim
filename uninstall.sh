#!/usr/bin/env bash
# Canadian Timezone Shim - Uninstall script
# Safely removes only files created by the shim
# Handles legacy installations and edge cases

set -euo pipefail

# Determine installation scope
if [[ $EUID -eq 0 ]]; then
    ZONEINFO_DIR="/usr/local/share/zoneinfo"
    STATE_DIR="/var/lib/canadian-tz-shim"
    SYSTEM_WIDE=true
else
    ZONEINFO_DIR="${HOME}/.tzinfo"
    STATE_DIR="${HOME}/.local/state/canadian-tz-shim"
    SYSTEM_WIDE=false
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zones.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

header() {
    echo -e "${BLUE}$*${NC}"
}

# Parse command line arguments
FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force, -f    Force uninstallation even if restoration fails"
            echo "  --help, -h     Show this help message"
            echo ""
            echo "The uninstaller will:"
            echo "  1. Stop and remove systemd services (system-wide only)"
            echo "  2. Restore /etc/localtime to the original timezone"
            echo "  3. Remove patched timezone files"
            echo "  4. Remove state and configuration files"
            echo ""
            echo "If restoration fails, the uninstaller will exit without removing"
            echo "files to avoid breaking the system. Use --force to override."
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

header "Canadian Timezone Shim Uninstaller"
echo ""

if [[ "$SYSTEM_WIDE" == "true" ]]; then
    echo "This will remove system-wide patched timezones from: $ZONEINFO_DIR"
    echo ""
    echo "WARNING: /etc/localtime will be restored to the original system timezone."
    echo ""
else
    echo "This will remove user patched timezones from: $ZONEINFO_DIR"
fi
echo ""
read -p "Are you sure you want to continue? [y/N] " -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Uninstallation cancelled."
    exit 0
fi

# Remove systemd service if it exists
if [[ "$SYSTEM_WIDE" == "true" ]] && command -v systemctl &>/dev/null; then
    # Check for current service name
    if systemctl is-active --quiet canadian-tz-shim.path 2>/dev/null; then
        info "Stopping systemd service..."
        systemctl stop canadian-tz-shim.path
        systemctl disable canadian-tz-shim.path
    fi

    # Remove current service files
    if [[ -f /etc/systemd/system/canadian-tz-shim.service ]]; then
        info "Removing systemd service files..."
        rm -f /etc/systemd/system/canadian-tz-shim.service
        rm -f /etc/systemd/system/canadian-tz-shim.path
        systemctl daemon-reload
    fi

    # Check for legacy service names (older versions)
    for legacy_service in canadian-tz-shim.service canadian-tz-shim.path; do
        if systemctl is-active --quiet "$legacy_service" 2>/dev/null; then
            info "Stopping legacy systemd service: $legacy_service"
            systemctl stop "$legacy_service" 2>/dev/null || true
            systemctl disable "$legacy_service" 2>/dev/null || true
        fi
        if [[ -f "/etc/systemd/system/$legacy_service" ]]; then
            info "Removing legacy systemd service file: $legacy_service"
            rm -f "/etc/systemd/system/$legacy_service"
            systemctl daemon-reload 2>/dev/null || true
        fi
    done

    # Remove legacy installation directories
    for legacy_dir in /usr/local/libexec/canadian-tz-shim /usr/local/share/canadian-tz-shim; do
        if [[ -d "$legacy_dir" ]]; then
            info "Removing legacy directory: $legacy_dir"
            rm -rf "$legacy_dir"
        fi
    done
fi

# Restore /etc/localtime if system-wide (BEFORE removing files)
restoration_failed=false
if [[ "$SYSTEM_WIDE" == "true" ]]; then
    # Try to read original timezone from config file
    original_timezone=""
    original_timezone_path=""
    
    if [[ -f /etc/tzshim.conf ]]; then
        # Source the config file to get variables
        source /etc/tzshim.conf
        original_timezone="${original_timezone:-}"
        original_timezone_path="${original_timezone_path:-}"
    fi

    # If we have original timezone info, try to restore
    if [[ -n "$original_timezone" ]]; then
        # Restore to the original timezone name
        if [[ -f "/usr/share/zoneinfo/$original_timezone" ]]; then
            info "Restoring /etc/localtime to original timezone: $original_timezone"
            if ln -sf "/usr/share/zoneinfo/$original_timezone" /etc/localtime; then
                info "✓ /etc/localtime restored successfully"
            else
                error "Failed to restore /etc/localtime"
                restoration_failed=true
            fi
        else
            warn "Original timezone file not found: /usr/share/zoneinfo/$original_timezone"
            warn "/etc/localtime not restored"
            restoration_failed=true
        fi
    elif [[ -n "$original_timezone_path" ]]; then
        # Restore to the original path
        if [[ -f "$original_timezone_path" ]]; then
            info "Restoring /etc/localtime to original path: $original_timezone_path"
            if ln -sf "$original_timezone_path" /etc/localtime; then
                info "✓ /etc/localtime restored successfully"
            else
                error "Failed to restore /etc/localtime"
                restoration_failed=true
            fi
        else
            warn "Original timezone file not found: $original_timezone_path"
            warn "/etc/localtime not restored"
            restoration_failed=true
        fi
    else
        # No config file or no original timezone info
        # This can happen with older versions or corrupted installations
        warn "No original timezone information found"
        
        # Try to detect what timezone was originally set
        # Check if /etc/localtime currently points to one of our patched zones
        current_target=$(readlink -f /etc/localtime 2>/dev/null || echo "")
        
        if [[ -n "$current_target" ]]; then
            # Check if it's pointing to one of our patched zones
            is_patched=false
            if [[ -f "$CONFIG_FILE" ]]; then
                while IFS='|' read -r iana_zone _rest; do
                    [[ "$iana_zone" =~ ^#.*$ ]] && continue
                    [[ -z "$iana_zone" ]] && continue
                    
                    patched_path="${ZONEINFO_DIR}/${iana_zone}"
                    if [[ "$current_target" == "$patched_path" ]]; then
                        is_patched=true
                        break
                    fi
                done < "$CONFIG_FILE"
            fi
            
            if [[ "$is_patched" == "true" ]]; then
                warn "/etc/localtime currently points to a patched zone"
                warn "Cannot determine original timezone automatically"
                
                # Try to suggest a reasonable default based on the patched zone
                suggested_zone=""
                case "$current_target" in
                    *Vancouver*) suggested_zone="America/Los_Angeles" ;;
                    *Edmonton*) suggested_zone="America/Denver" ;;
                    *Whitehorse*|*Dawson*) suggested_zone="America/Vancouver" ;;
                    *Winnipeg*) suggested_zone="America/Chicago" ;;
                    *Yellowknife*) suggested_zone="America/Edmonton" ;;
                esac
                
                if [[ -n "$suggested_zone" && -f "/usr/share/zoneinfo/$suggested_zone" ]]; then
                    warn "Suggested restoration target: $suggested_zone"
                    warn "This is a reasonable default but may not match your original timezone"
                    
                    if [[ "$FORCE" == "true" ]]; then
                        info "Force mode: restoring to $suggested_zone"
                        if ln -sf "/usr/share/zoneinfo/$suggested_zone" /etc/localtime; then
                            info "✓ /etc/localtime restored to $suggested_zone"
                            restoration_failed=false
                        else
                            error "Failed to restore /etc/localtime"
                            restoration_failed=true
                        fi
                    else
                        warn "Run with --force to use suggested restoration, or restore manually"
                        restoration_failed=true
                    fi
                else
                    restoration_failed=true
                fi
            else
                # /etc/localtime doesn't point to a patched zone
                # Maybe it was already restored or never changed
                info "/etc/localtime does not point to a patched zone"
                info "No restoration needed"
                restoration_failed=false
            fi
        else
            warn "Cannot read /etc/localtime"
            restoration_failed=true
        fi
    fi

    # Remove the config file if it exists
    if [[ -f /etc/tzshim.conf ]]; then
        rm -f /etc/tzshim.conf
        info "Removed /etc/tzshim.conf"
    fi
else
    # User mode: clean up config file if it exists
    if [[ -f "${HOME}/.config/tzshim.conf" ]]; then
        rm -f "${HOME}/.config/tzshim.conf"
        info "Removed ~/.config/tzshim.conf"
    fi
    
    # Check for legacy config locations
    for legacy_config in "${HOME}/.tzshim.conf" "${HOME}/.config/canadian-tz-shim.conf"; do
        if [[ -f "$legacy_config" ]]; then
            info "Removing legacy config file: $legacy_config"
            rm -f "$legacy_config"
        fi
    done
fi

# If restoration failed and not in force mode, don't remove the timezone files
if [[ "$restoration_failed" == "true" && "$SYSTEM_WIDE" == "true" && "$FORCE" != "true" ]]; then
    error "Restoration of /etc/localtime failed."
    error "Keeping timezone files in $ZONEINFO_DIR to avoid breaking the system."
    error ""
    error "Options:"
    error "  1. Manually restore /etc/localtime to the correct timezone"
    error "  2. Re-run uninstall with --force to proceed anyway"
    error ""
    error "To manually restore, run:"
    error "  sudo ln -sf /usr/share/zoneinfo/YOUR_TIMEZONE /etc/localtime"
    exit 1
fi

if [[ "$restoration_failed" == "true" && "$FORCE" == "true" ]]; then
    warn "Force mode: proceeding despite restoration failure"
fi

# Remove state directory
if [[ -d "$STATE_DIR" ]]; then
    info "Removing state directory..."
    rm -rf "$STATE_DIR"
fi

# Check for legacy state directories
for legacy_state in "${HOME}/.local/state/canadian-tz-shim" "/var/lib/canadian-tz-shim"; do
    if [[ -d "$legacy_state" && "$legacy_state" != "$STATE_DIR" ]]; then
        info "Removing legacy state directory: $legacy_state"
        rm -rf "$legacy_state"
    fi
done

# Safely remove only the timezone files we created
if [[ -d "$ZONEINFO_DIR" ]]; then
    info "Removing patched timezone files..."

    # Read zones.conf to know which files we created
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='|' read -r iana_zone _rest; do
            [[ "$iana_zone" =~ ^#.*$ ]] && continue
            [[ -z "$iana_zone" ]] && continue

            target_file="${ZONEINFO_DIR}/${iana_zone}"
            if [[ -f "$target_file" ]]; then
                rm -f "$target_file"
                info "  Removed: $iana_zone"
            fi

            # Remove backup files too (current pattern)
            for backup in "${target_file}.backup."*; do
                if [[ -f "$backup" ]]; then
                    rm -f "$backup"
                fi
            done
            
            # Check for legacy backup patterns
            for legacy_backup in "${target_file}.bak" "${target_file}.old" "${target_file}~"; do
                if [[ -f "$legacy_backup" ]]; then
                    info "  Removed legacy backup: $(basename "$legacy_backup")"
                    rm -f "$legacy_backup"
                fi
            done
        done < "$CONFIG_FILE"
    fi

    # Check for orphaned files (files in ZONEINFO_DIR not in zones.conf)
    if [[ -f "$CONFIG_FILE" ]]; then
        orphaned_files=()
        while IFS= read -r -d '' file; do
            filename=$(basename "$file")
            # Check if this file is in our zones.conf
            is_known=false
            while IFS='|' read -r iana_zone _rest; do
                [[ "$iana_zone" =~ ^#.*$ ]] && continue
                [[ -z "$iana_zone" ]] && continue
                if [[ "$filename" == "$iana_zone" ]]; then
                    is_known=true
                    break
                fi
            done < "$CONFIG_FILE"
            
            # Check if it's a backup file
            if [[ "$filename" == *.backup.* ]] || [[ "$filename" == *.bak ]] || [[ "$filename" == *.old ]]; then
                is_known=true
            fi
            
            if [[ "$is_known" == "false" ]]; then
                orphaned_files+=("$file")
            fi
        done < <(find "$ZONEINFO_DIR" -type f -print0 2>/dev/null)
        
        if [[ ${#orphaned_files[@]} -gt 0 ]]; then
            warn "Found ${#orphaned_files[@]} orphaned file(s) from previous installation:"
            for orphaned in "${orphaned_files[@]}"; do
                warn "  $(basename "$orphaned")"
            done
            warn "These files will not be removed automatically"
            warn "Remove them manually if they are from an older version"
        fi
    fi

    # Try to remove empty directories
    if [[ -d "$ZONEINFO_DIR" ]]; then
        # Only remove if directory is empty or contains only our files
        if [[ -z "$(ls -A "$ZONEINFO_DIR" 2>/dev/null)" ]]; then
            rmdir "$ZONEINFO_DIR" 2>/dev/null || true
            info "Removed empty directory: $ZONEINFO_DIR"
        else
            # Check if remaining files are not ours
            remaining=$(find "$ZONEINFO_DIR" -type f 2>/dev/null | wc -l)
            if [[ $remaining -gt 0 ]]; then
                warn "Directory $ZONEINFO_DIR contains other files, not removing"
                warn "Remaining files: $remaining"
            else
                rmdir "$ZONEINFO_DIR" 2>/dev/null || true
            fi
        fi
    fi
fi

# Check for legacy installation directories
for legacy_dir in "${HOME}/.zoneinfo" "${HOME}/.tzinfo"; do
    if [[ -d "$legacy_dir" && "$legacy_dir" != "$ZONEINFO_DIR" ]]; then
        warn "Found legacy installation directory: $legacy_dir"
        warn "This may be from an older version of the shim"
        warn "Remove it manually if no longer needed: rm -rf $legacy_dir"
    fi
done

info "✓ Uninstallation complete."
echo ""

if [[ "$SYSTEM_WIDE" == "false" ]]; then
    echo "Remember to remove the TZ export from your shell profile if you added it:"
    echo ""
    echo "    export TZ=\$HOME/.tzinfo/America/Vancouver"
    echo ""
fi

if [[ "$restoration_failed" == "true" && "$FORCE" == "true" ]]; then
    warn "Note: /etc/localtime was not restored due to missing metadata"
    warn "You may need to manually set your timezone:"
    warn "  sudo ln -sf /usr/share/zoneinfo/YOUR_TIMEZONE /etc/localtime"
    echo ""
fi
