#!/usr/bin/env bash
# Canadian Timezone Shim - Install script
# Patches Canadian timezone files to use official provincial/territorial abbreviations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zones.conf"

# Determine installation scope
if [[ $EUID -eq 0 ]]; then
    # Running as root: install system-wide
    ZONEINFO_DIR="/usr/local/share/zoneinfo"
    SYSTEM_WIDE=true
    STATE_DIR="/var/lib/canadian-tz-shim"
else
    # Running as user: install to home directory
    ZONEINFO_DIR="${HOME}/.tzinfo"
    SYSTEM_WIDE=false
    STATE_DIR="${HOME}/.local/state/canadian-tz-shim"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
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

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Check if zdump is available
if ! command -v zdump &>/dev/null; then
    error "zdump command not found. Please install tzdata package."
    exit 1
fi

header "Canadian Timezone Shim Installer"
echo ""
echo "This tool patches Canadian timezone files to use official provincial/territorial"
echo "abbreviations instead of IANA's convention choices."
echo ""

if [[ "$SYSTEM_WIDE" == "true" ]]; then
    echo "Installation mode: SYSTEM-WIDE (requires root)"
    echo "Patched zones will be installed to: $ZONEINFO_DIR"
    echo ""
else
    echo "Installation mode: USER-ONLY"
    echo "Patched zones will be installed to: $ZONEINFO_DIR"
    echo ""
fi

# Detect current timezone
detect_current_timezone() {
    if [[ -L /etc/localtime ]]; then
        local target
        target=$(readlink -f /etc/localtime)
        # Extract zone name from path
        if [[ "$target" =~ /zoneinfo/(.*) ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    return 1
}

# Show menu for timezone selection
# Display goes to /dev/tty (visible to user), return value goes to stdout
show_timezone_menu() {
    local zones=()
    local names=()

    while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
        [[ "$iana_zone" =~ ^#.*$ ]] && continue
        [[ -z "$iana_zone" ]] && continue
        zones+=("$iana_zone")
        names+=("$official_name ($official_abbrev)")
    done < "$CONFIG_FILE"

    # All display output goes to /dev/tty so it's not captured by $()
    echo "" >&2
    echo "Select your timezone:" >&2
    echo "" >&2
    for i in "${!zones[@]}"; do
        echo "  $((i+1))) ${zones[$i]} - ${names[$i]}" >&2
    done
    echo "" >&2

    local choice=""
    while true; do
        read -r -p "Enter choice [1-${#zones[@]}]: " choice </dev/tty >&2
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#zones[@]} ]]; then
            # Only the selection goes to stdout for capture
            echo "${zones[$((choice-1))]}"
            return 0
        fi
        echo "Invalid choice. Please enter a number between 1 and ${#zones[@]}." >&2
    done
}

# Validate that a timezone identifier is in our config
validate_zone() {
    local zone="$1"
    while IFS='|' read -r iana_zone _rest; do
        [[ "$iana_zone" =~ ^#.*$ ]] && continue
        [[ -z "$iana_zone" ]] && continue
        if [[ "$iana_zone" == "$zone" ]]; then
            return 0
        fi
    done < "$CONFIG_FILE"
    return 1
}

# Targeted binary patcher: patches only TZif abbreviation pools and POSIX footer
# This is safer than global sed because it only modifies known abbreviation locations
patch_tzif_file() {
    local file="$1"
    local old_abbrev="$2"
    local new_abbrev="$3"

    # Both must be exactly 3 bytes for safe replacement
    if [[ ${#old_abbrev} -ne 3 ]] || [[ ${#new_abbrev} -ne 3 ]]; then
        error "Abbreviations must be exactly 3 characters"
        return 1
    fi

    # Use the external Python patcher script
    local patcher_script="${SCRIPT_DIR}/lib/patch_tzif.py"
    if [[ ! -f "$patcher_script" ]]; then
        error "Patcher script not found: $patcher_script"
        return 1
    fi

    python3 "$patcher_script" "$file" "$old_abbrev" "$new_abbrev" 2>/dev/null
}

# Verify a patched TZif file is structurally sound
verify_tzif_integrity() {
    local patched_file="$1"
    local original_file="$2"

    # Check file sizes match (equal-length replacement preserves size)
    local patched_size original_size
    patched_size=$(stat -c%s "$patched_file")
    original_size=$(stat -c%s "$original_file")

    if [[ "$patched_size" != "$original_size" ]]; then
        error "File size changed: $original_size → $patched_size"
        return 1
    fi

    # Use zdump to verify the file is still a valid timezone file
    if ! zdump -v "$patched_file" &>/dev/null; then
        error "zdump cannot parse patched file"
        return 1
    fi

    return 0
}

# Determine which zone to activate (system-wide only)
selected_zone=""
original_timezone=""
if [[ "$SYSTEM_WIDE" == "true" ]]; then
    current_tz=$(detect_current_timezone || echo "")

    # Check if current timezone matches one of our zones
    matched=false
    while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
        [[ "$iana_zone" =~ ^#.*$ ]] && continue
        [[ -z "$iana_zone" ]] && continue

        if [[ "$current_tz" == "$iana_zone" ]]; then
            selected_zone="$iana_zone"
            matched=true
            info "Detected current timezone: $iana_zone ($official_name)"
            break
        fi
    done < "$CONFIG_FILE"

    # If no match, show menu
    if [[ "$matched" == "false" ]]; then
        if [[ -n "$current_tz" ]]; then
            warn "Current timezone ($current_tz) is not in the Canadian shim list."
        else
            warn "Could not detect current timezone."
        fi
        selected_zone=$(show_timezone_menu) || exit 1

        # Validate the selection
        if ! validate_zone "$selected_zone"; then
            error "Invalid timezone selection: $selected_zone"
            exit 1
        fi
    fi

    # Save the original timezone for restoration during uninstall
    original_timezone="$current_tz"
fi

# Read configuration and process each zone
patched_count=0
skipped_count=0
error_count=0

while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
    # Skip comments and empty lines
    [[ "$iana_zone" =~ ^#.*$ ]] && continue
    [[ -z "$iana_zone" ]] && continue

    system_zone="/usr/share/zoneinfo/${iana_zone}"
    target_zone="${ZONEINFO_DIR}/${iana_zone}"
    target_dir="$(dirname "$target_zone")"

    # Print initial status line
    echo -en "${BLUE}Processing:${NC} $iana_zone ($official_name) ... "

    # Check if system zoneinfo file exists
    if [[ ! -f "$system_zone" ]]; then
        echo -e "${YELLOW}SKIP${NC} (zone file not found)"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    # Idempotency check: if already patched, skip
    if [[ -f "$target_zone" ]]; then
        # Check if the official abbreviation is already present in recent dates
        verify_year="2026"
        if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
            verify_year="2020"
        fi

        # Capture zdump output to avoid pipe buffering issues
        zdump_output=$(zdump -v "$target_zone" 2>/dev/null)
        if echo "$zdump_output" | grep -q "$verify_year.*$official_abbrev"; then
            echo -e "${YELLOW}SKIP${NC} (already patched)"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        # Backup existing file before overwriting
        cp "$target_zone" "${target_zone}.backup.$(date +%s)"
    fi

    # Create directory structure
    mkdir -p "$target_dir"

    # Copy system zoneinfo file
    cp "$system_zone" "$target_zone"

    # Patch the file using targeted binary patching
    patch_count=$(patch_tzif_file "$target_zone" "$iana_abbrev" "$official_abbrev" 2>/dev/null) || patch_count=0

    if [[ "$patch_count" -gt 0 ]]; then
        # Verify structural integrity
        if verify_tzif_integrity "$target_zone" "$system_zone"; then
            # Verify the abbreviation appears in recent dates
            verify_year="2026"
            if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
                verify_year="2020"
            fi

            zdump_output=$(zdump -v "$target_zone")
            pattern="$verify_year.*$official_abbrev"

            if echo "$zdump_output" | grep -q "$pattern"; then
                echo -e "${GREEN}✓${NC} $iana_abbrev → $official_abbrev ($patch_count locations)"
                patched_count=$((patched_count + 1))
            else
                echo -e "${RED}✗${NC} verification failed"
                error_count=$((error_count + 1))
            fi
        else
            echo -e "${RED}✗${NC} integrity check failed"
            error_count=$((error_count + 1))
        fi
    else
        echo -e "${RED}✗${NC} no locations patched"
        error_count=$((error_count + 1))
    fi

done < "$CONFIG_FILE"

# Summary
header "Installation Summary"
echo ""
echo "  Zones patched: $patched_count"
echo "  Zones skipped: $skipped_count"
echo "  Errors: $error_count"
echo ""

if [[ $patched_count -gt 0 || ($skipped_count -gt 0 && $error_count -eq 0) ]]; then
    if [[ $patched_count -gt 0 ]]; then
        info "Installation complete!"
    else
        info "All zones are already patched. No changes needed."
    fi
    echo ""

    if [[ "$SYSTEM_WIDE" == "true" ]]; then
        # Store selected zone for systemd service
        mkdir -p "$STATE_DIR"
        echo "$selected_zone" > "${STATE_DIR}/selected-zone"

        # Save original timezone to /etc/tzshim.conf for restoration during uninstall
        if [[ -n "$original_timezone" ]]; then
            echo "original_timezone=$original_timezone" > /etc/tzshim.conf
            info "Saved original timezone to /etc/tzshim.conf: $original_timezone"
        else
            # If we couldn't detect the original, save the current /etc/localtime target
            if [[ -L /etc/localtime ]]; then
                current_link=$(readlink -f /etc/localtime)
                echo "original_timezone_path=$current_link" > /etc/tzshim.conf
                info "Saved original /etc/localtime target to /etc/tzshim.conf: $current_link"
            fi
        fi

        # Create symlink to /etc/localtime
        target_zone="${ZONEINFO_DIR}/${selected_zone}"
        if [[ -f "$target_zone" ]]; then
            ln -sf "$target_zone" /etc/localtime
            info "Updated /etc/localtime → $selected_zone"
        fi

        # Install systemd service
        if command -v systemctl &>/dev/null; then
            mkdir -p /usr/local/libexec/canadian-tz-shim
            cp "${SCRIPT_DIR}/lib/reapply.sh" /usr/local/libexec/canadian-tz-shim/
            chmod +x /usr/local/libexec/canadian-tz-shim/reapply.sh

            # Copy the patch helper if it exists as a standalone script
            if [[ -f "${SCRIPT_DIR}/lib/patch_tzif.py" ]]; then
                cp "${SCRIPT_DIR}/lib/patch_tzif.py" /usr/local/libexec/canadian-tz-shim/
                chmod +x /usr/local/libexec/canadian-tz-shim/patch_tzif.py
            fi

            mkdir -p /usr/local/share/canadian-tz-shim
            cp "${SCRIPT_DIR}/zones.conf" /usr/local/share/canadian-tz-shim/

            cp "${SCRIPT_DIR}/lib/canadian-tz-shim.service" /etc/systemd/system/
            cp "${SCRIPT_DIR}/lib/canadian-tz-shim.path" /etc/systemd/system/

            systemctl daemon-reload
            systemctl enable canadian-tz-shim.path
            systemctl start canadian-tz-shim.path

            info "Installed systemd service to watch for tzdata updates"
        fi

        echo ""
        echo "The shim is now active system-wide. Changes take effect immediately."
        echo ""
        echo "To verify:"
        echo "  date +'%Z %z'"

        # Extract official abbreviation for selected zone
        while IFS='|' read -r iana_zone iana_abbrev official_abbrev official_name reference_url; do
            [[ "$iana_zone" =~ ^#.*$ ]] && continue
            [[ -z "$iana_zone" ]] && continue
            if [[ "$iana_zone" == "$selected_zone" ]]; then
                echo "  # Should show: $official_abbrev"
                break
            fi
        done < "$CONFIG_FILE"
    else
        # Save original timezone to ~/.config/tzshim.conf for restoration during uninstall
        current_tz=$(detect_current_timezone || echo "")
        mkdir -p "${HOME}/.config"
        if [[ -n "$current_tz" ]]; then
            echo "original_timezone=$current_tz" > "${HOME}/.config/tzshim.conf"
            info "Saved original timezone to ~/.config/tzshim.conf: $current_tz"
        else
            # If we couldn't detect the original, save the current /etc/localtime target
            if [[ -L /etc/localtime ]]; then
                current_link=$(readlink -f /etc/localtime)
                echo "original_timezone_path=$current_link" > "${HOME}/.config/tzshim.conf"
                info "Saved original /etc/localtime target to ~/.config/tzshim.conf: $current_link"
            fi
        fi

        echo "To use the patched timezones, set TZ to the patched zone path:"
        echo ""
        echo "  # For Vancouver (Pacific Time):"
        echo "  export TZ=${ZONEINFO_DIR}/America/Vancouver"
        echo ""
        echo "  # For Edmonton (Alberta Time):"
        echo "  export TZ=${ZONEINFO_DIR}/America/Edmonton"
        echo ""
        echo "  # For Whitehorse (Yukon Standard Time):"
        echo "  export TZ=${ZONEINFO_DIR}/America/Whitehorse"
        echo ""
        echo "  # For Winnipeg (Manitoba Standard Time):"
        echo "  export TZ=${ZONEINFO_DIR}/America/Winnipeg"
        echo ""
        echo "  # For Yellowknife (Northwest Territories Time):"
        echo "  export TZ=${ZONEINFO_DIR}/America/Yellowknife"
        echo ""
        echo "Add the export to your shell profile (~/.bashrc, ~/.zshrc, etc.) for persistence."
        echo ""
        echo "For system-wide installation with automatic updates, run this script as root:"
        echo "  sudo $0"
    fi

    echo ""
    echo "To uninstall, run: ./uninstall.sh"
else
    error "No zones were patched. Please check the errors above."
    exit 1
fi
