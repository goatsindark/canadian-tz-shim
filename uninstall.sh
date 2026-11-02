#!/usr/bin/env bash
# Canadian Timezone Shim - Uninstall script
# Removes the patched timezone files and systemd service

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

header "Canadian Timezone Shim Uninstaller"
echo ""

if [[ "$SYSTEM_WIDE" == "true" ]]; then
    echo "This will remove system-wide patched timezones: $ZONEINFO_DIR"
    echo ""
    echo "WARNING: /etc/localtime will be restored to the original system timezone."
    echo ""
else
    echo "This will remove user patched timezones: $ZONEINFO_DIR"
fi
echo ""
read -p "Are you sure you want to continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Uninstallation cancelled."
    exit 0
fi

# Remove systemd service if it exists
if [[ "$SYSTEM_WIDE" == "true" ]] && command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet canadian-tz-shim.path 2>/dev/null; then
        info "Stopping systemd service..."
        systemctl stop canadian-tz-shim.path
        systemctl disable canadian-tz-shim.path
    fi
    
    if [[ -f /etc/systemd/system/canadian-tz-shim.service ]]; then
        info "Removing systemd service files..."
        rm -f /etc/systemd/system/canadian-tz-shim.service
        rm -f /etc/systemd/system/canadian-tz-shim.path
        systemctl daemon-reload
    fi
    
    if [[ -d /usr/local/libexec/canadian-tz-shim ]]; then
        rm -rf /usr/local/libexec/canadian-tz-shim
    fi
    
    if [[ -d /usr/local/share/canadian-tz-shim ]]; then
        rm -rf /usr/local/share/canadian-tz-shim
    fi
fi

# Remove state directory
if [[ -d "$STATE_DIR" ]]; then
    info "Removing state directory..."
    rm -rf "$STATE_DIR"
fi

# Restore /etc/localtime if system-wide
if [[ "$SYSTEM_WIDE" == "true" ]]; then
    # Read original timezone from /etc/tzshim.conf
    if [[ -f /etc/tzshim.conf ]]; then
        # Source the config file to get variables
        source /etc/tzshim.conf

        if [[ -n "${original_timezone:-}" ]]; then
            # Restore to the original timezone name
            if [[ -f "/usr/share/zoneinfo/$original_timezone" ]]; then
                info "Restoring /etc/localtime to original timezone: $original_timezone"
                ln -sf "/usr/share/zoneinfo/$original_timezone" /etc/localtime
            else
                warn "Original timezone file not found: /usr/share/zoneinfo/$original_timezone"
                warn "/etc/localtime not restored"
            fi
        elif [[ -n "${original_timezone_path:-}" ]]; then
            # Restore to the original path
            if [[ -f "$original_timezone_path" ]]; then
                info "Restoring /etc/localtime to original path: $original_timezone_path"
                ln -sf "$original_timezone_path" /etc/localtime
            else
                warn "Original timezone file not found: $original_timezone_path"
                warn "/etc/localtime not restored"
            fi
        else
            warn "No original timezone information found in /etc/tzshim.conf"
            warn "/etc/localtime not restored"
        fi

        # Remove the config file
        rm -f /etc/tzshim.conf
        info "Removed /etc/tzshim.conf"
    else
        warn "/etc/tzshim.conf not found"
        warn "Cannot determine original timezone"
        warn "/etc/localtime not restored"
    fi
else
    # User mode: clean up ~/.config/tzshim.conf if it exists
    if [[ -f "${HOME}/.config/tzshim.conf" ]]; then
        rm -f "${HOME}/.config/tzshim.conf"
        info "Removed ~/.config/tzshim.conf"
    fi
fi

# Remove the directory
if [[ -d "$ZONEINFO_DIR" ]]; then
    info "Removing $ZONEINFO_DIR..."
    rm -rf "$ZONEINFO_DIR"
fi

info "✓ Uninstallation complete."
echo ""

if [[ "$SYSTEM_WIDE" == "false" ]]; then
    echo "Remember to remove the TZ export from your shell profile if you added it:"
    echo ""
    echo "    export TZ=\$HOME/.tzinfo/America/Vancouver"
    echo ""
fi
