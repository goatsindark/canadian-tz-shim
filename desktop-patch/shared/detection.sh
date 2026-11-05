#!/usr/bin/env bash
# Desktop Environment Detection
# Detects the current desktop environment and version

set -euo pipefail

# Detection result variables
DETECTED_DESKTOP=""
DETECTED_VERSION=""
DETECTED_CONFIDENCE=""  # high, medium, low
DETECTED_SESSION_TYPE=""

# Detect the current desktop environment
detect_desktop_environment() {
    DETECTED_DESKTOP=""
    DETECTED_VERSION=""
    DETECTED_CONFIDENCE="low"
    DETECTED_SESSION_TYPE=""
    
    # Get session type
    if [[ -n "${XDG_SESSION_TYPE:-}" ]]; then
        DETECTED_SESSION_TYPE="$XDG_SESSION_TYPE"
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        DETECTED_SESSION_TYPE="wayland"
    elif [[ -n "${DISPLAY:-}" ]]; then
        DETECTED_SESSION_TYPE="x11"
    fi
    
    # Primary detection: XDG_CURRENT_DESKTOP
    local xdg_current="${XDG_CURRENT_DESKTOP:-}"
    local xdg_session="${XDG_SESSION_DESKTOP:-}"
    local desktop_session="${DESKTOP_SESSION:-}"
    
    # Normalize to lowercase for matching
    xdg_current="${xdg_current,,}"
    xdg_session="${xdg_session,,}"
    desktop_session="${desktop_session,,}"
    
    # KDE Plasma detection
    if [[ "$xdg_current" == *"kde"* ]] || [[ "$xdg_session" == *"kde"* ]] || \
       [[ "$desktop_session" == *"kde"* ]]; then
        DETECTED_DESKTOP="kde"
        DETECTED_CONFIDENCE="high"
        
        if command -v plasmashell &>/dev/null; then
            local plasma_version
            plasma_version=$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$plasma_version" ]]; then
                DETECTED_VERSION="$plasma_version"
            fi
        fi
        return 0
    fi
    
    # Budgie detection (check before GNOME since Budgie is GNOME-based)
    if [[ "$xdg_current" == *"budgie"* ]] || [[ "$xdg_session" == *"budgie"* ]] || \
       [[ "$desktop_session" == *"budgie"* ]]; then
        DETECTED_DESKTOP="budgie"
        DETECTED_CONFIDENCE="high"
        
        if command -v budgie-desktop &>/dev/null; then
            local budgie_version
            budgie_version=$(budgie-desktop --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$budgie_version" ]]; then
                DETECTED_VERSION="$budgie_version"
            fi
        fi
        return 0
    fi
    
    # GNOME detection
    if [[ "$xdg_current" == *"gnome"* ]] || [[ "$xdg_session" == *"gnome"* ]] || \
       [[ "$desktop_session" == *"gnome"* ]]; then
        DETECTED_DESKTOP="gnome"
        DETECTED_CONFIDENCE="high"
        
        if command -v gnome-shell &>/dev/null; then
            local gnome_version
            gnome_version=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$gnome_version" ]]; then
                DETECTED_VERSION="$gnome_version"
            fi
        fi
        return 0
    fi
    
    # Cinnamon detection
    if [[ "$xdg_current" == *"x-cinnamon"* ]] || [[ "$xdg_session" == *"cinnamon"* ]] || \
       [[ "$desktop_session" == *"cinnamon"* ]]; then
        DETECTED_DESKTOP="cinnamon"
        DETECTED_CONFIDENCE="high"
        
        if command -v cinnamon &>/dev/null; then
            local cinnamon_version
            cinnamon_version=$(cinnamon --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$cinnamon_version" ]]; then
                DETECTED_VERSION="$cinnamon_version"
            fi
        fi
        return 0
    fi
    
    # XFCE detection
    if [[ "$xdg_current" == *"xfce"* ]] || [[ "$xdg_session" == *"xfce"* ]] || \
       [[ "$desktop_session" == *"xfce"* ]]; then
        DETECTED_DESKTOP="xfce"
        DETECTED_CONFIDENCE="high"
        
        if command -v xfce4-panel &>/dev/null; then
            local xfce_version
            xfce_version=$(xfce4-panel --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$xfce_version" ]]; then
                DETECTED_VERSION="$xfce_version"
            fi
        fi
        return 0
    fi
    
    # MATE detection
    if [[ "$xdg_current" == *"mate"* ]] || [[ "$xdg_session" == *"mate"* ]] || \
       [[ "$desktop_session" == *"mate"* ]]; then
        DETECTED_DESKTOP="mate"
        DETECTED_CONFIDENCE="high"
        
        if command -v mate-panel &>/dev/null; then
            local mate_version
            mate_version=$(mate-panel --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$mate_version" ]]; then
                DETECTED_VERSION="$mate_version"
            fi
        fi
        return 0
    fi
    
    # LXQt detection
    if [[ "$xdg_current" == *"lxqt"* ]] || [[ "$xdg_session" == *"lxqt"* ]] || \
       [[ "$desktop_session" == *"lxqt"* ]]; then
        DETECTED_DESKTOP="lxqt"
        DETECTED_CONFIDENCE="high"
        
        if command -v lxqt-panel &>/dev/null; then
            local lxqt_version
            lxqt_version=$(lxqt-panel --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ -n "$lxqt_version" ]]; then
                DETECTED_VERSION="$lxqt_version"
            fi
        fi
        return 0
    fi
    
    # No desktop detected
    return 1
}

# Get desktop display name with distribution hints
get_desktop_display_name() {
    local desktop="$1"
    case "$desktop" in
        kde)
            echo "KDE Plasma (Kubuntu, KDE neon, Fedora KDE)"
            ;;
        gnome)
            echo "GNOME (Ubuntu, Fedora Workstation)"
            ;;
        cinnamon)
            echo "Cinnamon (Linux Mint Cinnamon)"
            ;;
        xfce)
            echo "XFCE (Xubuntu, Linux Mint XFCE)"
            ;;
        mate)
            echo "MATE (Ubuntu MATE, Linux Mint MATE)"
            ;;
        budgie)
            echo "Budgie (Ubuntu Budgie)"
            ;;
        lxqt)
            echo "LXQt (Lubuntu)"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# Get the configuration backend for a desktop
get_desktop_backend() {
    local desktop="$1"
    case "$desktop" in
        kde)
            echo "kconfig"
            ;;
        gnome|cinnamon|mate|budgie)
            echo "gsettings"
            ;;
        xfce)
            echo "xfconf"
            ;;
        lxqt)
            echo "lxqt"
            ;;
        *)
            echo ""
            ;;
    esac
}
