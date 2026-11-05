#!/usr/bin/env bash
# Canadian Timezone Shim - Desktop Configuration Utility
# Companion tool that configures the user's selected Linux desktop environment
# to work correctly with the Canadian timezone shim.
#
# This utility is SEPARATE from the core timezone installer.
# The core installer owns: patched TZif files, /etc/localtime, system timezone
# selection, systemd reapplication, and core install/upgrade/uninstall.
#
# This utility owns ONLY: desktop-environment presentation and clock configuration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_PATCH_VERSION="2.0.0"

# Path to the shared zones.conf (the core installer's config, source of truth
# for the source → custom-id mapping).
DESKTOP_PATCH_ZONES_CONF="$(cd "${SCRIPT_DIR}/.." && pwd)/zones.conf"

# State directory for manifests and backups
STATE_DIR="${HOME}/.local/state/canadian-tz-shim/desktop-patches"

# Source shared components
source "${SCRIPT_DIR}/shared/detection.sh"
source "${SCRIPT_DIR}/shared/backup.sh"
source "${SCRIPT_DIR}/shared/manifest.sh"
source "${SCRIPT_DIR}/shared/verification.sh"
source "${SCRIPT_DIR}/shared/ui.sh"

# Source the core's custom-zones library for the source↔custom mapping
source "${SCRIPT_DIR}/../lib/custom_zones.sh"

# Source backends
source "${SCRIPT_DIR}/backends/kconfig.sh"
source "${SCRIPT_DIR}/backends/gsettings.sh"
source "${SCRIPT_DIR}/backends/xfconf.sh"
source "${SCRIPT_DIR}/backends/lxqt.sh"

# Source adapters
source "${SCRIPT_DIR}/adapters/kde.sh"
source "${SCRIPT_DIR}/adapters/gnome.sh"
source "${SCRIPT_DIR}/adapters/cinnamon.sh"
source "${SCRIPT_DIR}/adapters/xfce.sh"
source "${SCRIPT_DIR}/adapters/mate.sh"
source "${SCRIPT_DIR}/adapters/budgie.sh"
source "${SCRIPT_DIR}/adapters/lxqt.sh"

# ============================================================================
# Safety checks
# ============================================================================

# Refuse to run as root for desktop patching
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        dp_error "Desktop patching must not run as root."
        dp_error "Desktop configuration belongs to the logged-in user, not root."
        dp_error "Please run this script as the desktop user."
        exit 1
    fi
}

# Refuse to modify another user's home directory
check_correct_user() {
    local target_home="${1:-$HOME}"
    
    # Get the logged-in user from the session
    local session_user="${USER:-}"
    if [[ -z "$session_user" ]]; then
        session_user=$(id -un 2>/dev/null || echo "")
    fi
    
    # Get the owner of the target home
    local target_owner
    target_owner=$(stat -c '%U' "$target_home" 2>/dev/null || echo "")
    
    if [[ -n "$session_user" ]] && [[ -n "$target_owner" ]]; then
        if [[ "$session_user" != "$target_owner" ]]; then
            dp_error "Refusing to modify another user's home directory."
            dp_error "Session user: $session_user"
            dp_error "Target home owner: $target_owner"
            exit 1
        fi
    fi
    
    # Refuse sudo without proper session user detection
    if [[ -n "${SUDO_USER:-}" ]] && [[ -z "${DISPLAY:-}" ]] && [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        dp_warn "Running under sudo without a desktop session."
        dp_warn "Desktop patching requires an active desktop session."
        dp_warn "Please run as the desktop user directly."
        exit 1
    fi
}

# ============================================================================
# Adapter dispatch
# ============================================================================

# Get the adapter functions for a desktop
# Arguments: $1 = desktop name
# Returns: adapter prefix on stdout (e.g., "kde", "gnome")
get_adapter() {
    local desktop="$1"
    case "$desktop" in
        kde) echo "kde" ;;
        gnome) echo "gnome" ;;
        cinnamon) echo "cinnamon" ;;
        xfce) echo "xfce" ;;
        mate) echo "mate" ;;
        budgie) echo "budgie" ;;
        lxqt) echo "lxqt" ;;
        *) echo "" ;;
    esac
}

# Call an adapter function
# Arguments: $1 = desktop, $2 = operation, $3... = args
adapter_call() {
    local desktop="$1"
    local operation="$2"
    shift 2
    
    local prefix
    prefix=$(get_adapter "$desktop")
    
    if [[ -z "$prefix" ]]; then
        dp_error "Unknown desktop: $desktop"
        return 1
    fi
    
    local func="${prefix}_${operation}"
    
    if ! type "$func" &>/dev/null; then
        dp_error "Adapter function not found: $func"
        return 1
    fi
    
    "$func" "$@"
}

# ============================================================================
# Selected timezone detection
# ============================================================================

# Get the currently selected Canadian timezone from the shim
get_selected_timezone() {
    # Check system-wide state
    if [[ -f "/var/lib/canadian-tz-shim/selected-zone" ]]; then
        cat "/var/lib/canadian-tz-shim/selected-zone"
        return 0
    fi
    
    # Check user-level state
    if [[ -f "${HOME}/.local/state/canadian-tz-shim/selected-zone" ]]; then
        cat "${HOME}/.local/state/canadian-tz-shim/selected-zone"
        return 0
    fi
    
    # Try to detect from /etc/localtime
    if [[ -L /etc/localtime ]]; then
        local target
        target=$(readlink -f /etc/localtime)
        if [[ "$target" =~ /zoneinfo/(.*) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    
    return 1
}

# ============================================================================
# Commands
# ============================================================================

# Show status of all desktops
cmd_status() {
    dp_header "Canadian Timezone Shim - Desktop Status"
    echo ""
    
    local selected_tz
    selected_tz=$(get_selected_timezone) || selected_tz="(not detected)"
    
    echo "Selected timezone: $selected_tz"
    echo ""
    
    # Detect current desktop
    if detect_desktop_environment; then
        local display_name
        display_name=$(get_desktop_display_name "$DETECTED_DESKTOP")
        echo "Current session: ${DP_BOLD}${display_name}${DP_NC}"
        if [[ -n "$DETECTED_VERSION" ]]; then
            echo "Version: $DETECTED_VERSION"
        fi
        echo ""
        
        # Show status for current desktop
        adapter_call "$DETECTED_DESKTOP" "status"
    else
        echo "No desktop environment detected."
        echo ""
        echo "Available adapters:"
        for desktop in kde gnome cinnamon xfce mate budgie lxqt; do
            echo "  - $desktop"
        done
    fi
    
    echo ""
    
    # Show existing patches
    if [[ -d "$STATE_DIR" ]]; then
        local manifests
        manifests=$(find "$STATE_DIR" -name "manifest-*.json" 2>/dev/null | sort)
        if [[ -n "$manifests" ]]; then
            echo "Applied desktop patches:"
            while IFS= read -r manifest; do
                local info
                info=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(f\"  {d.get('timestamp', '?')}: {d.get('desktop', '?')} - {d.get('verification', '?')}\")
" "$manifest" 2>/dev/null) || continue
                echo "$info"
            done <<< "$manifests"
        else
            echo "No desktop patches have been applied."
        fi
    else
        echo "No desktop patches have been applied."
    fi
}

# Apply desktop patch
# Arguments: $1 = desktop, $2 = dry run
cmd_apply() {
    local desktop="$1"
    local dry_run="${2:-false}"
    
    check_not_root
    check_correct_user
    
    # Get selected timezone
    local selected_tz
    selected_tz=$(get_selected_timezone) || {
        dp_error "Cannot determine the selected Canadian timezone."
        dp_error "Please install the Canadian timezone shim first."
        exit 1
    }
    
    dp_header "Configuring $desktop for Canadian timezone: $selected_tz"
    echo ""
    
    # Inspect current state
    adapter_call "$desktop" "inspect"
    echo ""
    
    # Plan changes
    adapter_call "$desktop" "plan" "$selected_tz"
    echo ""
    
    if [[ "$dry_run" == "true" ]]; then
        echo "DRY RUN: No changes will be made."
        adapter_call "$desktop" "apply" "$selected_tz" "1" "$STATE_DIR" "true"
        return 0
    fi
    
    # For desktops with multiple applets, ask which one to configure
    local applet_index="1"
    
    # Confirm changes
    if ! confirm_changes "Apply the above changes?"; then
        dp_info "Cancelled."
        return 0
    fi
    
    # Apply
    adapter_call "$desktop" "apply" "$selected_tz" "$applet_index" "$STATE_DIR" "false"
}

# Restore from manifest
# Arguments: $1 = manifest file (optional, latest if not specified)
cmd_restore() {
    local manifest="${1:-}"
    
    check_not_root
    check_correct_user
    
    if [[ ! -d "$STATE_DIR" ]]; then
        dp_error "No desktop patches have been applied."
        exit 1
    fi
    
    # Find the latest manifest if not specified
    if [[ -z "$manifest" ]]; then
        manifest=$(find "$STATE_DIR" -name "manifest-*.json" 2>/dev/null | sort -r | head -1)
        if [[ -z "$manifest" ]]; then
            dp_error "No manifests found."
            exit 1
        fi
    fi
    
    if [[ ! -f "$manifest" ]]; then
        dp_error "Manifest not found: $manifest"
        exit 1
    fi
    
    # Show manifest info
    dp_header "Restoring from manifest:"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(f\"  Desktop: {d.get('desktop', '?')}\")
print(f\"  Timestamp: {d.get('timestamp', '?')}\")
print(f\"  Timezone: {d.get('timezone', '?')}\")
print(f\"  Changes: {len(d.get('changes', []))}\")
print(f\"  Verification: {d.get('verification', '?')}\")
" "$manifest"
    echo ""
    
    # Check if current values have changed since patching
    local current_changed=false
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for change in d.get('changes', []):
    print(f\"  {change.get('target', '?')}: {change.get('new_value', '?')} -> {change.get('original_value', '?')}\")
" "$manifest"
    echo ""
    
    if ! confirm_changes "Restore these settings to their original values?"; then
        dp_info "Cancelled."
        return 0
    fi
    
    # Get desktop from manifest
    local desktop
    desktop=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('desktop', ''))
" "$manifest")
    
    if [[ -z "$desktop" ]]; then
        dp_error "Cannot determine desktop from manifest."
        exit 1
    fi
    
    adapter_call "$desktop" "restore" "$manifest" "$STATE_DIR"
}

# Show help
cmd_help() {
    cat <<EOF
Canadian Timezone Shim - Desktop Configuration Utility v${DESKTOP_PATCH_VERSION}

This utility configures your desktop environment's clock to work correctly
with the Canadian timezone shim. It is SEPARATE from the core timezone
installer.

USAGE:
    $0 [OPTIONS]
    $0 --desktop DESKTOP [OPTIONS]

OPTIONS:
    --desktop DESKTOP    Select desktop environment (kde, gnome, cinnamon,
                         xfce, mate, budgie, lxqt)
    --detect             Detect and recommend desktop environment
    --status             Show current desktop configuration status
    --restore            Restore previous configuration from manifest
    --dry-run            Show what would be done without making changes
    --help, -h           Show this help message

INTERACTIVE MODE:
    Run without arguments to see the interactive menu.

EXAMPLES:
    $0                              # Interactive menu
    $0 --desktop kde                # Configure KDE Plasma
    $0 --desktop gnome --dry-run    # Show what GNOME changes would be made
    $0 --detect                     # Detect and recommend
    $0 --status                     # Show current status
    $0 --restore                    # Restore last applied configuration

SUPPORTED DESKTOPS:
    kde       KDE Plasma (Kubuntu, KDE neon, Fedora KDE)
    gnome     GNOME (Ubuntu, Fedora Workstation)
    cinnamon  Cinnamon (Linux Mint Cinnamon)
    xfce      XFCE (Xubuntu, Linux Mint XFCE)
    mate      MATE (Ubuntu MATE, Linux Mint MATE)
    budgie    Budgie (Ubuntu Budgie)
    lxqt      LXQt (Lubuntu)

SAFETY:
    - Runs as the desktop user, never as root
    - Backs up all modified files
    - Records all changes in a manifest
    - Supports dry-run mode
    - Idempotent (safe to run multiple times)
    - Restores only settings changed by this utility

STATE:
    Manifests and backups are stored in:
    ${STATE_DIR}

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Parse arguments
    local desktop=""
    local action=""
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --desktop)
                desktop="$2"
                shift 2
                ;;
            --detect)
                action="detect"
                shift
                ;;
            --status)
                action="status"
                shift
                ;;
            --restore)
                action="restore"
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --help|-h)
                cmd_help
                exit 0
                ;;
            *)
                dp_error "Unknown option: $1"
                dp_error "Use --help for usage information."
                exit 1
                ;;
        esac
    done
    
    # Handle actions
    case "$action" in
        status)
            cmd_status
            exit 0
            ;;
        restore)
            cmd_restore
            exit 0
            ;;
        detect)
            if detect_desktop_environment; then
                local display_name
                display_name=$(get_desktop_display_name "$DETECTED_DESKTOP")
                dp_success "Detected: ${DP_BOLD}${display_name}${DP_NC}"
                if [[ -n "$DETECTED_VERSION" ]]; then
                    echo "Version: $DETECTED_VERSION"
                fi
                echo "Confidence: $DETECTED_CONFIDENCE"
                echo ""
                
                if [[ "$DETECTED_CONFIDENCE" == "high" ]]; then
                    if confirm_changes "Configure $DETECTED_DESKTOP?"; then
                        desktop="$DETECTED_DESKTOP"
                    else
                        exit 0
                    fi
                else
                    dp_warn "Low confidence detection. Please select manually."
                    desktop=$(show_main_menu) || exit 0
                fi
            else
                dp_warn "No desktop environment detected."
                desktop=$(show_main_menu) || exit 0
            fi
            ;;
    esac
    
    # If no desktop specified, show interactive menu
    if [[ -z "$desktop" ]]; then
        # Try to detect first
        detect_desktop_environment || true
        
        desktop=$(show_main_menu "$DETECTED_DESKTOP" "$DETECTED_CONFIDENCE" "$DETECTED_VERSION") || exit 0
        
        # Handle special menu choices
        case "$desktop" in
            detect)
                if detect_desktop_environment; then
                    local display_name
                    display_name=$(get_desktop_display_name "$DETECTED_DESKTOP")
                    dp_success "Detected: ${DP_BOLD}${display_name}${DP_NC}"
                    if [[ -n "$DETECTED_VERSION" ]]; then
                        echo "Version: $DETECTED_VERSION"
                    fi
                    echo ""
                    
                    if confirm_changes "Configure $DETECTED_DESKTOP?"; then
                        desktop="$DETECTED_DESKTOP"
                    else
                        exit 0
                    fi
                else
                    dp_error "No desktop environment detected."
                    exit 1
                fi
                ;;
            status)
                cmd_status
                exit 0
                ;;
            restore)
                cmd_restore
                exit 0
                ;;
        esac
    fi
    
    # Validate desktop
    local valid_desktops="kde gnome cinnamon xfce mate budgie lxqt"
    if ! echo "$valid_desktops" | grep -qw "$desktop"; then
        dp_error "Invalid desktop: $desktop"
        dp_error "Valid options: $valid_desktops"
        exit 1
    fi
    
    # Apply
    if [[ "$dry_run" == "true" ]]; then
        cmd_apply "$desktop" "true"
    else
        cmd_apply "$desktop" "false"
    fi
}

main "$@"
