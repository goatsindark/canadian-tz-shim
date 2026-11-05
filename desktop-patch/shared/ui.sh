#!/usr/bin/env bash
# User interface utilities for desktop-patch
# Handles interactive menus, prompts, and output formatting

set -euo pipefail

# Color codes
DP_RED='\033[0;31m'
DP_GREEN='\033[0;32m'
DP_YELLOW='\033[1;33m'
DP_BLUE='\033[0;34m'
DP_BOLD='\033[1m'
DP_NC='\033[0m'

# Output functions
dp_info() {
    echo -e "${DP_GREEN}[INFO]${DP_NC} $*"
}

dp_warn() {
    echo -e "${DP_YELLOW}[WARN]${DP_NC} $*"
}

dp_error() {
    echo -e "${DP_RED}[ERROR]${DP_NC} $*" >&2
}

dp_header() {
    echo -e "${DP_BLUE}${DP_BOLD}$*${DP_NC}"
}

dp_success() {
    echo -e "${DP_GREEN}✓${DP_NC} $*"
}

dp_fail() {
    echo -e "${DP_RED}✗${DP_NC} $*"
}

# Show the main interactive menu
# Arguments: $1 = detected desktop (may be empty)
#            $2 = detected confidence (high/medium/low)
#            $3 = detected version (may be empty)
# Returns: selected desktop identifier on stdout
show_main_menu() {
    local detected_desktop="${1:-}"
    local detected_confidence="${2:-low}"
    local detected_version="${3:-}"
    
    dp_header "Canadian Timezone Shim - Desktop Configuration"
    echo ""
    
    if [[ -n "$detected_desktop" ]]; then
        local display_name
        display_name=$(get_desktop_display_name "$detected_desktop")
        echo "Detected desktop: ${DP_BOLD}${display_name}${DP_NC}"
        if [[ -n "$detected_version" ]]; then
            echo "Version: ${detected_version}"
        fi
        echo "Confidence: ${detected_confidence}"
        echo ""
    fi
    
    echo "Select a desktop environment to configure:"
    echo ""
    echo "  1) KDE Plasma       (Kubuntu, KDE neon, Fedora KDE)"
    echo "  2) GNOME            (Ubuntu, Fedora Workstation)"
    echo "  3) Cinnamon         (Linux Mint Cinnamon)"
    echo "  4) XFCE             (Xubuntu, Linux Mint XFCE)"
    echo "  5) MATE             (Ubuntu MATE, Linux Mint MATE)"
    echo "  6) Budgie           (Ubuntu Budgie)"
    echo "  7) LXQt             (Lubuntu)"
    echo "  8) Detect and recommend"
    echo "  9) Show current status"
    echo " 10) Restore a previous configuration"
    echo "  0) Exit"
    echo ""
    
    local choice
    while true; do
        read -p "Enter choice [0-10]: " -r choice
        
        case "$choice" in
            1) echo "kde"; return 0 ;;
            2) echo "gnome"; return 0 ;;
            3) echo "cinnamon"; return 0 ;;
            4) echo "xfce"; return 0 ;;
            5) echo "mate"; return 0 ;;
            6) echo "budgie"; return 0 ;;
            7) echo "lxqt"; return 0 ;;
            8) echo "detect"; return 0 ;;
            9) echo "status"; return 0 ;;
            10) echo "restore"; return 0 ;;
            0) return 1 ;;
            *) echo "Invalid choice. Please enter 0-10." ;;
        esac
    done
}

# Ask for confirmation before making changes
# Arguments: $1 = description of changes
# Returns: 0 if confirmed, 1 if declined
confirm_changes() {
    local description="$1"
    
    echo ""
    echo "$description"
    echo ""
    
    local reply
    read -p "Apply these changes? [y/N]: " -r reply
    
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Ask for confirmation before reloading a component
# Arguments: $1 = component name, $2 = reason
# Returns: 0 if confirmed, 1 if declined
confirm_reload() {
    local component="$1"
    local reason="$2"
    
    echo ""
    echo "A reload of ${component} is recommended: ${reason}"
    echo "This will NOT be done automatically."
    echo ""
    
    local reply
    read -p "Reload ${component} now? [y/N]: " -r reply
    
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Select from multiple clock applets/plugins
# Arguments: $1 = applet count, $2... = applet descriptions
# Returns: selected index (1-based) on stdout
select_applet() {
    local count="$1"
    shift
    local descriptions=("$@")
    
    if [[ "$count" -eq 1 ]]; then
        echo "1"
        return 0
    fi
    
    echo ""
    echo "Multiple clock applets detected. Select one to configure:"
    echo ""
    
    local i
    for i in $(seq 1 "$count"); do
        echo "  ${i}) ${descriptions[$((i-1))]}"
    done
    echo ""
    
    local choice
    while true; do
        read -p "Enter choice [1-${count}]: " -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
            echo "$choice"
            return 0
        else
            echo "Invalid choice. Please enter 1-${count}."
        fi
    done
}
