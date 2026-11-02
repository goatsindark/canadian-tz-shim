#!/usr/bin/env bash
# Canadian Timezone Shim - Install script with upgrade support
# Patches Canadian timezone files to use official provincial/territorial abbreviations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zones.conf"
MIGRATIONS_FILE="${SCRIPT_DIR}/migrations.json"
CURRENT_VERSION="1.0.0"

# Parse command-line arguments
UPGRADE_MODE=false
DRY_RUN=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --upgrade)
            UPGRADE_MODE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Show help if requested
if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<EOF
Usage: $0 [OPTIONS]

Canadian Timezone Shim Installer

Options:
  --upgrade          Upgrade existing installation to current version
  --dry-run          Show what would be done without making changes
  --help, -h         Show this help message

Examples:
  $0                          # Fresh installation
  $0 --upgrade                # Upgrade existing installation
  $0 --upgrade --dry-run      # Show upgrade plan without executing

EOF
    exit 0
fi

# Determine installation scope
if [[ $EUID -eq 0 ]]; then
    # Running as root: install system-wide
    ZONEINFO_DIR="/usr/local/share/zoneinfo"
    SYSTEM_WIDE=true
    STATE_DIR="/var/lib/canadian-tz-shim"
    CONFIG_PATH="/etc/tzshim.conf"
else
    # Running as user: install to home directory
    ZONEINFO_DIR="${HOME}/.tzinfo"
    SYSTEM_WIDE=false
    STATE_DIR="${HOME}/.local/state/canadian-tz-shim"
    CONFIG_PATH="${HOME}/.config/tzshim.conf"
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

# Source upgrade library if in upgrade mode
if [[ "$UPGRADE_MODE" == "true" ]]; then
    if [[ ! -f "${SCRIPT_DIR}/lib/upgrade.sh" ]]; then
        error "Upgrade library not found: ${SCRIPT_DIR}/lib/upgrade.sh"
        exit 1
    fi
    source "${SCRIPT_DIR}/lib/upgrade.sh"
fi

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

# ============================================================================
# Upgrade Mode
# ============================================================================

if [[ "$UPGRADE_MODE" == "true" ]]; then
    header "Canadian Timezone Shim - Upgrade Mode"
    echo ""
    
    # Discover existing installation
    info "Discovering existing installation..."
    discover_installation "$SYSTEM_WIDE" "$ZONEINFO_DIR" "$STATE_DIR" "$CONFIG_PATH"
    
    # Report discovery results
    report_installation_status
    
    # Determine upgrade action
    info "Determining upgrade action..."
    determine_upgrade_action "$CURRENT_VERSION" "$MIGRATIONS_FILE"
    
    # Report decision
    report_upgrade_decision "$CURRENT_VERSION"
    echo ""
    
    # Handle different states
    case "$UPGRADE_STATE" in
        "$UPGRADE_STATE_CURRENT")
            info "Installation is current and healthy. No action needed."
            exit 0
            ;;
        
        "$UPGRADE_STATE_NOT_INSTALLED")
            error "No existing installation found."
            error "Use '$0' without --upgrade for fresh installation."
            exit 1
            ;;
        
        "$UPGRADE_STATE_AMBIGUOUS")
            error "Cannot determine installation state reliably."
            error "Manual intervention required."
            error "Consider uninstalling and performing fresh installation."
            exit 1
            ;;
        
        "$UPGRADE_STATE_UNSUPPORTED")
            error "No supported upgrade path from ${INSTALLED_VERSION} to ${CURRENT_VERSION}"
            error "Manual intervention required."
            exit 1
            ;;
        
        "$UPGRADE_STATE_REPAIR_REQUIRED")
            warn "Installation requires repair."
            if [[ "$DRY_RUN" == "true" ]]; then
                info "Dry run: Would repair installation to ${CURRENT_VERSION}"
                exit 0
            fi
            # Fall through to execute repair
            ;;
        
        "$UPGRADE_STATE_UPGRADE_AVAILABLE")
            info "Upgrade available: ${INSTALLED_VERSION} → ${CURRENT_VERSION}"
            if [[ "$DRY_RUN" == "true" ]]; then
                info "Dry run: Would upgrade installation"
                exit 0
            fi
            # Fall through to execute upgrade
            ;;
    esac
    
    # Execute upgrade
    info "Executing upgrade..."
    if execute_upgrade "$DRY_RUN" "$ZONEINFO_DIR" "$STATE_DIR" "$CONFIG_PATH" "$MIGRATIONS_FILE"; then
        info "Upgrade completed successfully!"
        info "Installation is now at version ${CURRENT_VERSION}"
        exit 0
    else
        error "Upgrade failed."
        exit 1
    fi
fi

# ============================================================================
# Normal Installation Mode
# ============================================================================

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
original_timezone_path=""
if [[ "$SYSTEM_WIDE" == "true" ]]; then
    # Check if we already have saved original timezone metadata
    if [[ -f "$CONFIG_PATH" ]]; then
        source "$CONFIG_PATH"
        original_timezone="${original_timezone:-}"
        original_timezone_path="${original_timezone_path:-}"
        if [[ -n "$original_timezone" || -n "$original_timezone_path" ]]; then
            info "Preserving existing original timezone metadata"
        fi
    fi

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

    # Only save original timezone if we don't already have it
    if [[ -z "$original_timezone" && -z "$original_timezone_path" ]]; then
        if [[ -n "$current_tz" ]]; then
            original_timezone="$current_tz"
        elif [[ -L /etc/localtime ]]; then
            original_timezone_path=$(readlink -f /etc/localtime)
        fi
    fi
fi

# Read configuration and process each zone
patched_count=0
skipped_count=0
error_count=0
declare -a successfully_patched_zones=()

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

    # Validate source timezone file structure
    if ! zdump -v "$system_zone" &>/dev/null; then
        echo -e "${RED}SKIP${NC} (invalid source timezone file)"
        error_count=$((error_count + 1))
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
            successfully_patched_zones+=("$iana_zone")
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
                # Verify UTC offset is correct
                expected_offset=""
                case "$official_abbrev" in
                    PCT) expected_offset="-0700" ;;
                    ABT) expected_offset="-0600" ;;
                    YST) expected_offset="-0700" ;;
                    MBT) expected_offset="-0500" ;;
                    NWT) expected_offset="-0600" ;;
                esac

                if [[ -n "$expected_offset" ]]; then
                    # Test a date after the transition
                    test_date="2026-12-15"
                    if [[ "$iana_zone" == *"Whitehorse"* || "$iana_zone" == *"Dawson"* ]]; then
                        test_date="2021-06-15"
                    fi

                    actual_offset=$(TZ="$target_zone" date -d "$test_date 12:00:00" +"%z" 2>/dev/null || echo "")
                    if [[ "$actual_offset" == "$expected_offset" ]]; then
                        echo -e "${GREEN}✓${NC} $iana_abbrev → $official_abbrev ($patch_count locations)"
                        patched_count=$((patched_count + 1))
                        successfully_patched_zones+=("$iana_zone")
                    else
                        echo -e "${RED}✗${NC} UTC offset mismatch (expected $expected_offset, got $actual_offset)"
                        rm -f "$target_zone"
                        error_count=$((error_count + 1))
                    fi
                else
                    echo -e "${GREEN}✓${NC} $iana_abbrev → $official_abbrev ($patch_count locations)"
                    patched_count=$((patched_count + 1))
                    successfully_patched_zones+=("$iana_zone")
                fi
            else
                echo -e "${RED}✗${NC} verification failed"
                rm -f "$target_zone"
                error_count=$((error_count + 1))
            fi
        else
            echo -e "${RED}✗${NC} integrity check failed"
            rm -f "$target_zone"
            error_count=$((error_count + 1))
        fi
    else
        echo -e "${RED}✗${NC} no locations patched"
        rm -f "$target_zone"
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

# Determine installation status
if [[ $patched_count -eq 0 && $skipped_count -eq 0 ]]; then
    # Total failure
    error "No zones were patched. Installation failed."
    error "Please check the errors above and ensure tzdata is properly installed."
    exit 1
elif [[ $error_count -gt 0 && $patched_count -eq 0 ]]; then
    # All attempted patches failed
    error "All patch attempts failed. Installation incomplete."
    error "No timezone activation performed."
    exit 1
elif [[ $error_count -gt 0 ]]; then
    # Partial success
    warn "Partial installation: $patched_count succeeded, $error_count failed."
    warn "Only successfully patched zones will be activated."
fi

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

        # Save original timezone metadata (only if not already saved)
        if [[ ! -f "$CONFIG_PATH" ]]; then
            if [[ -n "$original_timezone" ]]; then
                {
                    echo "original_timezone=$original_timezone"
                    echo "installed_version=$CURRENT_VERSION"
                    echo "schema_version=1"
                } > "$CONFIG_PATH"
                info "Saved original timezone to $CONFIG_PATH: $original_timezone"
            elif [[ -n "$original_timezone_path" ]]; then
                {
                    echo "original_timezone_path=$original_timezone_path"
                    echo "installed_version=$CURRENT_VERSION"
                    echo "schema_version=1"
                } > "$CONFIG_PATH"
                info "Saved original /etc/localtime target to $CONFIG_PATH: $original_timezone_path"
            fi
        else
            # Update version in existing config
            if ! grep -q "^installed_version=" "$CONFIG_PATH" 2>/dev/null; then
                echo "installed_version=$CURRENT_VERSION" >> "$CONFIG_PATH"
            fi
            if ! grep -q "^schema_version=" "$CONFIG_PATH" 2>/dev/null; then
                echo "schema_version=1" >> "$CONFIG_PATH"
            fi
        fi

        # Create symlink to /etc/localtime only if the selected zone was successfully patched
        target_zone="${ZONEINFO_DIR}/${selected_zone}"
        if [[ -f "$target_zone" ]]; then
            ln -sf "$target_zone" /etc/localtime
            info "Updated /etc/localtime → $selected_zone"
        else
            warn "Selected zone $selected_zone was not successfully patched"
            warn "/etc/localtime not updated"
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
        # Save original timezone to ~/.config/tzshim.conf (only if not already saved)
        if [[ ! -f "$CONFIG_PATH" ]]; then
            current_tz=$(detect_current_timezone || echo "")
            mkdir -p "${HOME}/.config"
            if [[ -n "$current_tz" ]]; then
                {
                    echo "original_timezone=$current_tz"
                    echo "installed_version=$CURRENT_VERSION"
                    echo "schema_version=1"
                } > "$CONFIG_PATH"
                info "Saved original timezone to $CONFIG_PATH: $current_tz"
            elif [[ -L /etc/localtime ]]; then
                current_link=$(readlink -f /etc/localtime)
                {
                    echo "original_timezone_path=$current_link"
                    echo "installed_version=$CURRENT_VERSION"
                    echo "schema_version=1"
                } > "$CONFIG_PATH"
                info "Saved original /etc/localtime target to $CONFIG_PATH: $current_link"
            fi
        else
            # Update version in existing config
            if ! grep -q "^installed_version=" "$CONFIG_PATH" 2>/dev/null; then
                echo "installed_version=$CURRENT_VERSION" >> "$CONFIG_PATH"
            fi
            if ! grep -q "^schema_version=" "$CONFIG_PATH" 2>/dev/null; then
                echo "schema_version=1" >> "$CONFIG_PATH"
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
fi
