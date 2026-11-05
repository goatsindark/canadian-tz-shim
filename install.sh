#!/usr/bin/env bash
# Canadian Timezone Shim — Install script (v2, custom-zone architecture)
#
# The shim never modifies any official IANA TZif file. Instead it
# generates custom TZif files under the "Canadian/" namespace in the
# system zoneinfo tree, validates them against fixed historical dates,
# appends one narrow, idempotent, reversible registration line per
# custom identifier to zone.tab / zone1970.tab (so Qt's country() and
# comment() resolve), and points /etc/localtime at the selected custom
# zone. Every added line and every installed file is recorded in the
# ownership manifest so uninstall removes exactly what this project
# added and nothing else.
#
# Official IANA identifiers such as America/Vancouver are read as the
# *source* for a custom identifier such as Canadian/PCT. The source file
# is never written to. See zones.conf for the mapping.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zones.conf"
MIGRATIONS_FILE="${SCRIPT_DIR}/migrations.json"
CUSTOM_ZONES_LIB="${SCRIPT_DIR}/lib/custom_zones.sh"
PATCHER="${SCRIPT_DIR}/lib/patch_tzif.py"
CURRENT_VERSION="2.0.0"
CONFIG_SCHEMA_VERSION="2"

# Parse command-line arguments
UPGRADE_MODE=false
DRY_RUN=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --upgrade)  UPGRADE_MODE=true; shift ;;
        --dry-run)  DRY_RUN=true;         shift ;;
        --help|-h)  SHOW_HELP=true;       shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<EOF
Usage: $0 [OPTIONS]

Canadian Timezone Shim Installer (v2)

Options:
  --upgrade          Upgrade or repair an existing installation
  --dry-run          Show what would be done without making changes
  --help, -h         Show this help message

The installer generates custom "Canadian/<ABBR>" TZif identifiers under
/usr/share/zoneinfo/ (system-wide) or ~/.tzinfo/ (user-level), each built
from its IANA source file.  /etc/localtime is pointed at the selected
custom zone.  The official /usr/share/zoneinfo/America/* files are never
modified.  In system scope the installer also appends one narrow,
reversible registration line per custom identifier to
/usr/share/zoneinfo/zone.tab and zone1970.tab so Qt's
QTimeZone::country() / comment() resolve; uninstall removes exactly the
lines this project added and nothing else.

EOF
    exit 0
fi

# Determine installation scope
if [[ $EUID -eq 0 ]]; then
    SCOPE="system"
    ZONEINFO_DIR="/usr/share/zoneinfo"          # base for /usr/share/zoneinfo/Canadian/*
    STATE_DIR="/var/lib/canadian-tz-shim"
    CONFIG_PATH="/etc/tzshim.conf"
else
    SCOPE="user"
    ZONEINFO_DIR="${HOME}/.tzinfo"
    STATE_DIR="${HOME}/.local/state/canadian-tz-shim"
    CONFIG_PATH="${HOME}/.config/tzshim.conf"
fi

# Load custom-zone library
if [[ ! -f "$CUSTOM_ZONES_LIB" ]]; then
    echo "ERROR: lib/custom_zones.sh missing — cannot install" >&2
    exit 1
fi
# shellcheck source=lib/custom_zones.sh
source "$CUSTOM_ZONES_LIB"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "${BLUE}$*${NC}"; }

# ============================================================================
# Upgrade path (unchanged behaviour, but with a migration step 1.x → 2.x)
# ============================================================================

if [[ "$UPGRADE_MODE" == "true" ]]; then
    if [[ ! -f "${SCRIPT_DIR}/lib/upgrade.sh" ]]; then
        error "Upgrade library missing: lib/upgrade.sh"
        exit 1
    fi
    # shellcheck source=lib/upgrade.sh
    source "${SCRIPT_DIR}/lib/upgrade.sh"
    # Load the custom-zones library so the migration's generate_custom_zones
    # operation is available in-process.
    if [[ ! -f "${SCRIPT_DIR}/lib/custom_zones.sh" ]]; then
        error "Upgrade requires lib/custom_zones.sh"
        exit 1
    fi
    # shellcheck source=lib/custom_zones.sh
    source "${SCRIPT_DIR}/lib/custom_zones.sh"

    discover_installation "$([[ "$SCOPE" == "system" ]])" \
        "$ZONEINFO_DIR" "$STATE_DIR" "$CONFIG_PATH"
    determine_upgrade_action "$CURRENT_VERSION" "$MIGRATIONS_FILE"
    case "$UPGRADE_STATE" in
        not_installed) error "No existing installation found"; exit 1 ;;
        current)       info "Already up to date at $INSTALLED_VERSION"; exit 0 ;;
        unsupported)   error "Unsupported installed version: $INSTALLED_VERSION"; exit 1 ;;
        *) ;;
    esac
    if execute_upgrade "$DRY_RUN" "$ZONEINFO_DIR" "$STATE_DIR" \
                      "$CONFIG_PATH" "$MIGRATIONS_FILE"; then
        info "Upgrade completed."
        exit 0
    else
        error "Upgrade failed; previous state preserved."
        exit 1
    fi
fi

# ============================================================================
# Preflight: parse + validate zones.conf
# ============================================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    error "python3 is required (TZif patcher and manifest writer)"
    exit 1
fi

if ! ZONES_TSV="$(custom_zones_parse_file "$CONFIG_FILE" 2>&1)"; then
    error "zones.conf failed validation:"
    echo "$ZONES_TSV" >&2
    exit 1
fi
ZONE_COUNT=$(echo "$ZONES_TSV" | wc -l)
info "Parsed $ZONE_COUNT Canadian zones from $CONFIG_FILE"

# ============================================================================
# Timezone detection (system-wide)
# ============================================================================

detect_current_timezone() {
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

show_timezone_menu() {
    header "Select the timezone you want to activate:"
    echo ""
    local i=1
    local sources=()
    while IFS=$'\t' read -r src id _iab _oab name _url; do
        printf "  %d) %s (%s)   →  custom id: %s\n" "$i" "$src" "$name" "$id"
        sources+=("$src")
        i=$((i + 1))
    done <<< "$ZONES_TSV"
    echo ""
    local choice
    while true; do
        read -p "Enter choice [1-$i]: " -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= i )); then
            printf '%s\n' "${sources[$((choice - 1))]}"
            return 0
        fi
        echo "Invalid choice."
    done
}

selected_source_zone=""
original_timezone=""
original_timezone_path=""
selected_custom_zone=""

if [[ "$SCOPE" == "system" ]]; then
    # Preserve original restoration metadata if we already have it.
    if [[ -f "$CONFIG_PATH" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_PATH" || true
        original_timezone="${original_timezone:-}"
        original_timezone_path="${original_timezone_path:-}"
        if [[ -n "$original_timezone_path" ]]; then
            case "$original_timezone_path" in
                "$ZONEINFO_DIR"/Canadian/*|/usr/local/share/zoneinfo/*|"${HOME}/.tzinfo"/*)
                    warn "Discarding self-referential original_timezone_path"
                    original_timezone_path=""
                    ;;
            esac
        fi
        if [[ -n "$original_timezone" && ! -f "/usr/share/zoneinfo/$original_timezone" ]]; then
            warn "Discarding invalid original_timezone: $original_timezone"
            original_timezone=""
        fi
        if [[ -n "$original_timezone" || -n "$original_timezone_path" ]]; then
            info "Preserving existing original timezone metadata"
        fi
    fi

    current_tz=$(detect_current_timezone || echo "")

    # Match the current zone against either the IANA source or an already
    # installed custom zone (upgrade idempotency).
    matched=false
    while IFS=$'\t' read -r src id _iab _oab name _url; do
        if [[ "$current_tz" == "$src" ]] || [[ "$current_tz" == "$id" ]]; then
            selected_source_zone="$src"
            selected_custom_zone="$id"
            matched=true
            info "Detected current timezone: $src ($name) → $id"
            break
        fi
    done <<< "$ZONES_TSV"

    if [[ "$matched" == "false" ]]; then
        if [[ -n "$current_tz" ]]; then
            warn "Current timezone ($current_tz) is not in the Canadian shim list."
        else
            warn "Could not detect current timezone."
        fi
        selected_source_zone=$(show_timezone_menu) || exit 1
        # Resolve its custom id
        while IFS=$'\t' read -r src id _a _b _c _d; do
            if [[ "$src" == "$selected_source_zone" ]]; then
                selected_custom_zone="$id"
                break
            fi
        done <<< "$ZONES_TSV"
    fi

    if [[ -z "$selected_custom_zone" ]]; then
        error "Selected source has no custom id mapping"
        exit 1
    fi

    # Record the original timezone if we haven't yet.
    if [[ -z "$original_timezone" && -z "$original_timezone_path" ]]; then
        if [[ -n "$current_tz" ]] && [[ -f "/usr/share/zoneinfo/$current_tz" ]]; then
            original_timezone="$current_tz"
        elif [[ -L /etc/localtime ]]; then
            candidate=$(readlink -f /etc/localtime)
            case "$candidate" in
                /usr/share/zoneinfo/*) original_timezone_path="$candidate" ;;
                *) info "No canonical original timezone detectable; not writing restoration metadata" ;;
            esac
        fi
    fi
else
    # User scope: pick the source zone the same way.
    current_tz=$(detect_current_timezone || echo "")
    while IFS=$'\t' read -r src id _a _b _c _d; do
        if [[ "$current_tz" == "$src" ]]; then
            selected_source_zone="$src"
            selected_custom_zone="$id"
            break
        fi
    done <<< "$ZONES_TSV"
fi

# ============================================================================
# Dry-run reporting
# ============================================================================

if [[ "$DRY_RUN" == "true" ]]; then
    header "Dry run — planned changes (scope: $SCOPE)"
    echo ""
    echo "Base directory: ${ZONEINFO_DIR}"
    echo "Manifest:       $(custom_zones_manifest_path "$SCOPE")"
    echo "System state:   ${STATE_DIR}"
    if [[ "$SCOPE" == "system" ]]; then
        echo "Config:         ${CONFIG_PATH}"
        echo "/etc/localtime: would symlink to ${ZONEINFO_DIR}/${selected_custom_zone}"
    fi
    echo ""
    echo "Custom zones to install:"
    while IFS=$'\t' read -r src id iab oab _n _u; do
        echo "  ${src}  →  ${id}  (${iab} → ${oab})"
    done <<< "$ZONES_TSV"
    exit 0
fi

# ============================================================================
# Install custom zones
# ============================================================================

header "Installing Canadian custom zones (scope: $SCOPE)"
echo ""
patched=0; skipped=0; failed=0
declare -a installed_ids=()

while IFS=$'\t' read -r src id iab oab name _u; do
    echo -en "${BLUE}Processing:${NC} $src → $id (${name}) ... "
    if custom_zones_install "$SCOPE" "$src" "$id" "$iab" "$oab" "$PATCHER"; then
        echo -e "${GREEN}✓${NC}"
        patched=$((patched + 1))
        installed_ids+=("$id")
    else
        rc=$?
        echo -e "${RED}✗ (rc=$rc)${NC}"
        failed=$((failed + 1))
    fi
done <<< "$ZONES_TSV"

echo ""
header "Summary"
echo "  Installed: $patched"
echo "  Failed:    $failed"

if [[ $patched -eq 0 ]]; then
    error "No zones were installed. Nothing activated."
    exit 1
fi

if [[ $failed -gt 0 ]]; then
    warn "Partial installation: $patched succeeded, $failed failed."
    warn "Only successfully installed zones will be activated."
fi

# ============================================================================
# Persist state and activate /etc/localtime (system scope only)
# ============================================================================

mkdir -p "$STATE_DIR"
write_state_file() {
    local name="$1" value="$2"
    local target="${STATE_DIR}/${name}"
    local tmp="${target}.tmp.$$"
    printf '%s\n' "$value" > "$tmp"
    mv -T -- "$tmp" "$target"
}

# New state model: distinct source and custom, plus backward-compat file.
write_state_file "selected-source-zone" "$selected_source_zone"
write_state_file "selected-custom-zone" "$selected_custom_zone"
write_state_file "installed-scope" "$SCOPE"
write_state_file "installed-version" "$CURRENT_VERSION"

if [[ "$SCOPE" == "system" ]]; then
    # Save original-timezone metadata (preserved across reinstalls)
    if [[ ! -f "$CONFIG_PATH" ]] || ! grep -q '^original_' "$CONFIG_PATH" 2>/dev/null; then
        tmp="${CONFIG_PATH}.tmp.$$"
        {
            if [[ -n "$original_timezone" ]]; then
                echo "original_timezone=${original_timezone}"
            fi
            if [[ -n "$original_timezone_path" ]]; then
                echo "original_timezone_path=${original_timezone_path}"
            fi
            echo "installed_version=${CURRENT_VERSION}"
            echo "schema_version=${CONFIG_SCHEMA_VERSION}"
        } > "$tmp"
        mv -T -- "$tmp" "$CONFIG_PATH"
    else
        # Just bump version fields in the existing file
        if ! grep -q '^installed_version=' "$CONFIG_PATH"; then
            echo "installed_version=${CURRENT_VERSION}" >> "$CONFIG_PATH"
        fi
    fi

    # Symlink /etc/localtime to the custom zone we just installed.
    target="${ZONEINFO_DIR}/${selected_custom_zone}"
    if [[ -f "$target" ]]; then
        ln -sfn "$target" /etc/localtime
        info "/etc/localtime → ${selected_custom_zone}"
    else
        warn "Selected custom zone $selected_custom_zone not installed; /etc/localtime unchanged."
    fi

    # Install + enable systemd path/service so tzdata updates rebuild custom zones
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl daemon-reload 2>/dev/null; then
            systemd_ok=true
        else
            warn "systemd is not reachable (container? --user session?); skipping service install"
            systemd_ok=false
        fi
        if [[ "$systemd_ok" == "true" ]]; then
            if mkdir -p /usr/local/libexec/canadian-tz-shim 2>/dev/null; then
                install -m 0755 "${SCRIPT_DIR}/lib/reapply.sh" \
                    /usr/local/libexec/canadian-tz-shim/reapply.sh
                install -m 0755 "${SCRIPT_DIR}/lib/patch_tzif.py" \
                    /usr/local/libexec/canadian-tz-shim/patch_tzif.py
                install -m 0755 "${SCRIPT_DIR}/lib/custom_zones.sh" \
                    /usr/local/libexec/canadian-tz-shim/custom_zones.sh
                mkdir -p /usr/local/share/canadian-tz-shim
                install -m 0644 "${SCRIPT_DIR}/zones.conf" \
                    /usr/local/share/canadian-tz-shim/zones.conf
                install -m 0644 "${SCRIPT_DIR}/lib/canadian-tz-shim.service" \
                    /etc/systemd/system/canadian-tz-shim.service
                install -m 0644 "${SCRIPT_DIR}/lib/canadian-tz-shim.path" \
                    /etc/systemd/system/canadian-tz-shim.path
                systemctl enable canadian-tz-shim.path 2>/dev/null || true
                systemctl start  canadian-tz-shim.path 2>/dev/null || true
                info "Installed systemd path unit to rebuild custom zones on tzdata updates"
            else
                warn "Cannot write /usr/local/libexec/canadian-tz-shim — systemd watcher NOT installed."
                warn "Reapply after tzdata updates will need to be triggered manually."
            fi
        fi
    fi
else
    # User-scope config metadata only
    if [[ ! -f "$CONFIG_PATH" ]]; then
        mkdir -p "$(dirname "$CONFIG_PATH")"
        {
            echo "installed_version=${CURRENT_VERSION}"
            echo "schema_version=${CONFIG_SCHEMA_VERSION}"
            echo "scope=user"
        } > "$CONFIG_PATH"
    fi
fi

echo ""
header "Done."
echo ""
if [[ "$SCOPE" == "system" ]]; then
    echo "The shim is now active system-wide via a custom identifier."
    echo "Official /usr/share/zoneinfo/America/* files are untouched; the installer"
    echo "added narrow, reversible registration lines to zone.tab / zone1970.tab"
    echo "so Qt's country() and comment() resolve for the custom identifier."
    echo ""
    echo "Verification:"
    echo "  date +'%Z %z'    # should show $(echo "$ZONES_TSV" | awk -F'\t' -v s="$selected_source_zone" '$1==s{print $4}')"
    echo ""
    echo "KDE Plasma users: Qt parses zone.tab once at process start. Restart"
    echo "plasmashell once so the digital clock picks up the new tab entry:"
    echo "  systemctl --user restart plasma-plasmashell.service"
    echo "After that the clock follows /etc/localtime automatically and shows the"
    echo "Canadian abbreviation. If an individual clock applet stores an explicit"
    echo "IANA id (rather than 'Local'), the desktop-patch companion utility can"
    echo "migrate just that one stored value to the custom identifier."
    echo ""
    echo "To uninstall: sudo ${SCRIPT_DIR}/uninstall.sh"
else
    echo "Installed to: ${ZONEINFO_DIR}/"
    echo ""
    echo "To use the custom zones, set TZ to the full path:"
    echo ""
    while IFS=$'\t' read -r src id _a _b _c _d; do
        echo "  export TZ=${ZONEINFO_DIR}/${id}"
    done <<< "$ZONES_TSV"
    echo ""
    echo "Note: Qt (and therefore KDE, GNOME, and most other desktop clocks)"
    echo "searches /usr/share/zoneinfo/ only. It does not discover custom zones"
    echo "under \$HOME/.tzinfo/, and it does not honour \$TZDIR in current"
    echo "Qt 5 / Qt 6 builds. This user-scope install benefits the command line"
    echo "(\`date\`, \`TZ=.../Canadian/PCT\`) and Python's zoneinfo. For a desktop"
    echo "clock to show the Canadian abbreviation, install system-wide instead:"
    echo "  sudo ${SCRIPT_DIR}/install.sh"
fi
