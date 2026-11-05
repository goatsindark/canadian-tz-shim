#!/usr/bin/env bash
# Canadian Timezone Shim - Uninstall script (v2)
#
# Removes only files the shim recorded in its manifest as owned, restores
# /etc/localtime to the original recorded target, and cleans state.
# Never deletes an unowned file.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    SCOPE="system"
    ZONEINFO_DIR="/usr/share/zoneinfo"
    STATE_DIR="/var/lib/canadian-tz-shim"
else
    SCOPE="user"
    ZONEINFO_DIR="${HOME}/.tzinfo"
    STATE_DIR="${HOME}/.local/state/canadian-tz-shim"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zones.conf"
CUSTOM_ZONES_LIB="${SCRIPT_DIR}/lib/custom_zones.sh"
# The installer may have copied the library to the exec dir; if we run from a
# checkout, use the checkout.
if [[ ! -f "$CUSTOM_ZONES_LIB" ]]; then
    CUSTOM_ZONES_LIB="/usr/local/libexec/canadian-tz-shim/custom_zones.sh"
fi
if [[ -f "$CUSTOM_ZONES_LIB" ]]; then
    # shellcheck source=lib/custom_zones.sh
    source "$CUSTOM_ZONES_LIB"
fi

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "${BLUE}$*${NC}"; }

FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f) FORCE=true; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --force, -f  Force uninstallation even if restoration fails
  --help, -h   Show this help message

The uninstaller will:
  1. Stop and remove systemd services (system-wide)
  2. Restore /etc/localtime to the original timezone
  3. Remove ONLY the custom zones recorded in the shim manifest as owned
  4. Remove state and configuration files
EOF
            exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

header "Canadian Timezone Shim Uninstaller"
echo ""
if [[ "$SCOPE" == "system" ]]; then
    echo "This will remove custom Canadian zones from: ${ZONEINFO_DIR}/Canadian/"
    echo "/etc/localtime will be restored to the original system timezone."
else
    echo "This will remove custom Canadian zones from: ${ZONEINFO_DIR}/Canadian/"
fi
echo ""
read -p "Are you sure you want to continue? [y/N] " -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Uninstallation cancelled."
    exit 0
fi

# ============================================================================
# Stop systemd services (system scope)
# ============================================================================

if [[ "$SCOPE" == "system" ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet canadian-tz-shim.path 2>/dev/null; then
        info "Stopping systemd path unit..."
        systemctl stop canadian-tz-shim.path 2>/dev/null || true
        systemctl disable canadian-tz-shim.path 2>/dev/null || true
    fi
    for unit in canadian-tz-shim.service canadian-tz-shim.path; do
        if [[ -f "/etc/systemd/system/$unit" ]]; then
            rm -f "/etc/systemd/system/$unit"
            info "Removed /etc/systemd/system/$unit"
        fi
    done
    systemctl daemon-reload 2>/dev/null || true

    # Remove runtime install artifacts
    for d in /usr/local/libexec/canadian-tz-shim /usr/local/share/canadian-tz-shim; do
        if [[ -d "$d" ]]; then
            rm -rf -- "$d"
            info "Removed $d"
        fi
    done
fi

# ============================================================================
# Read state (must be BEFORE we delete the state dir)
# ============================================================================

CONFIG_PATH=""
if [[ "$SCOPE" == "system" ]]; then
    CONFIG_PATH="/etc/tzshim.conf"
else
    CONFIG_PATH="${HOME}/.config/tzshim.conf"
fi

original_timezone=""
original_timezone_path=""
selected_custom_zone=""
selected_source_zone=""

if [[ -f "$CONFIG_PATH" ]]; then
    # Read fields without executing arbitrary code
    while IFS='=' read -r k v; do
        case "$k" in
            original_timezone)       original_timezone="$v" ;;
            original_timezone_path)  original_timezone_path="$v" ;;
        esac
    done < "$CONFIG_PATH"
fi

if [[ -f "${STATE_DIR}/selected-source-zone" ]]; then
    selected_source_zone=$(<"${STATE_DIR}/selected-source-zone")
fi
if [[ -f "${STATE_DIR}/selected-custom-zone" ]]; then
    selected_custom_zone=$(<"${STATE_DIR}/selected-custom-zone")
fi
# Legacy field name from 1.x
if [[ -f "${STATE_DIR}/selected-zone" ]] && [[ -z "$selected_source_zone" ]]; then
    legacy=$(<"${STATE_DIR}/selected-zone")
    # In 1.x, selected-zone held the IANA id (e.g. America/Vancouver)
    selected_source_zone="$legacy"
fi

# ============================================================================
# Restore /etc/localtime BEFORE removing files
# ============================================================================

restoration_failed=false
if [[ "$SCOPE" == "system" ]]; then
    current_localtime=$(readlink /etc/localtime 2>/dev/null || echo "")

    # Is /etc/localtime currently pointing inside our Canadian/ install?
    is_shim_owned=false
    case "$current_localtime" in
        "${ZONEINFO_DIR}"/Canadian/*) is_shim_owned=true ;;
        "/usr/local/share/zoneinfo"/*) is_shim_owned=true ;;   # 1.x layout
        "${HOME}/.tzinfo"/*) is_shim_owned=true ;;
    esac

    if [[ "$is_shim_owned" == "true" ]]; then
        if [[ -n "$original_timezone" && -f "/usr/share/zoneinfo/$original_timezone" ]]; then
            if ln -sfn "/usr/share/zoneinfo/$original_timezone" /etc/localtime; then
                info "Restored /etc/localtime → ${original_timezone}"
            else
                error "Failed to restore /etc/localtime"
                restoration_failed=true
            fi
        elif [[ -n "$original_timezone_path" && -f "$original_timezone_path" ]]; then
            # Reject self-referential paths (from older buggy releases)
            case "$original_timezone_path" in
                "${ZONEINFO_DIR}"/Canadian/*|/usr/local/share/zoneinfo/*|*/.tzinfo/*)
                    warn "original_timezone_path resolves inside shim territory: $original_timezone_path"
                    rel="${original_timezone_path#/usr/local/share/zoneinfo/}"
                    rel="${rel#$ZONEINFO_DIR/}"
                    rel="${rel##*/.tzinfo/}"
                    if [[ -f "/usr/share/zoneinfo/${rel}" ]]; then
                        info "Recovering to equivalent system zone: $rel"
                        ln -sfn "/usr/share/zoneinfo/${rel}" /etc/localtime || restoration_failed=true
                    else
                        warn "No equivalent system timezone found"
                        restoration_failed=true
                    fi
                    ;;
                *)
                    if ln -sfn "$original_timezone_path" /etc/localtime; then
                        info "Restored /etc/localtime → ${original_timezone_path}"
                    else
                        restoration_failed=true
                    fi
                    ;;
            esac
        else
            warn "No original-timezone metadata available"
            if [[ "$FORCE" == "true" ]] && [[ -n "$selected_source_zone" ]]; then
                # Best-effort: fall back to a plausible sibling IANA zone.
                suggested=""
                case "$selected_source_zone" in
                    *Vancouver*)   suggested="America/Los_Angeles" ;;
                    *Edmonton*)    suggested="America/Denver" ;;
                    *Whitehorse*|*Dawson*) suggested="America/Vancouver" ;;
                    *Winnipeg*)    suggested="America/Chicago" ;;
                    *Yellowknife*) suggested="America/Edmonton" ;;
                esac
                if [[ -n "$suggested" && -f "/usr/share/zoneinfo/$suggested" ]]; then
                    info "Force mode: restoring to fallback $suggested"
                    ln -sfn "/usr/share/zoneinfo/$suggested" /etc/localtime || restoration_failed=true
                else
                    restoration_failed=true
                fi
            else
                restoration_failed=true
            fi
        fi
    else
        info "/etc/localtime does not point into shim territory; nothing to restore"
    fi
fi

# ============================================================================
# Refuse to delete anything while /etc/localtime still resolves into our paths
# ============================================================================

if [[ "$SCOPE" == "system" ]]; then
    after_restore=$(readlink -f /etc/localtime 2>/dev/null || echo "")
    case "$after_restore" in
        "${ZONEINFO_DIR}"/Canadian/*|/usr/local/share/zoneinfo/*)
            error "/etc/localtime still resolves into shim territory: $after_restore"
            error "Refusing to delete timezone files the system still depends on."
            if [[ "$FORCE" != "true" ]]; then
                error "Restore /etc/localtime manually and re-run, or use --force."
                exit 1
            else
                warn "Force mode: continuing despite dangling /etc/localtime"
            fi
            ;;
    esac
fi

if [[ "$restoration_failed" == "true" && "$SCOPE" == "system" && "$FORCE" != "true" ]]; then
    error "Restoration of /etc/localtime failed."
    error "Keeping timezone files to avoid breaking the system."
    error ""
    error "Options:"
    error "  1. Manually restore /etc/localtime to the correct timezone"
    error "  2. Re-run with --force to proceed anyway"
    exit 1
fi

# ============================================================================
# Remove custom zones (only files recorded as owned by us)
# ============================================================================

manifest="$(custom_zones_manifest_path "$SCOPE")"

if [[ -f "$manifest" ]] && command -v custom_zones_list_owned >/dev/null 2>&1; then
    info "Removing custom zones recorded as owned:"
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if custom_zones_remove_owned "$SCOPE" "$id"; then
            info "  removed $id"
        else
            rc=$?
            warn "  refused to remove $id (not owned by us, or hash changed)"
            if [[ "$FORCE" != "true" ]]; then
                error "Uninstall aborted. Investigate the file above or use --force."
                exit 1
            fi
        fi
    done < <(custom_zones_list_owned "$SCOPE")
else
    info "No custom-zone manifest found in $SCOPE scope; nothing generated by the shim to remove."
fi

# ============================================================================
# Clean up 1.x layout leftovers (files the pre-2.x installer left behind)
# These were at /usr/local/share/zoneinfo/America/<City>. Remove only files
# that look like Canadian-shim patches: abbreviation pool contains our
# OFFICIAL_ABBREV. This avoids deleting tzdata's own copies.
# ============================================================================

if [[ "$SCOPE" == "system" ]] && [[ -d "/usr/local/share/zoneinfo/America" ]] \
   && [[ -f "$CONFIG_FILE" ]] && command -v custom_zones_parse_file >/dev/null 2>&1; then
    while IFS=$'\t' read -r src _id iab oab _name _u; do
        [[ -z "$src" ]] && continue
        legacy="/usr/local/share/zoneinfo/${src}"
        [[ -f "$legacy" ]] || continue
        # Confirm the file's post-switch abbreviation is our official abbr
        # (i.e. it's a shim patch, not a stock tzdata copy that got placed here).
        pool="$(python3 - "$legacy" <<'PY'
import struct, sys
d=open(sys.argv[1],'rb').read()
if d[:4] != b'TZif':
    sys.exit(0)
c1=struct.unpack('>6I', d[20:44]); v1=44+c1[3]*4+c1[3]+c1[4]*6+c1[5]+c1[2]*12+c1[1]+c1[0]
if v1+44 > len(d) or d[v1:v1+4] != b'TZif':
    sys.exit(0)
c2=struct.unpack('>6I', d[v1+20:v1+44])
p=v1+44+c2[3]*8+c2[3]+c2[4]*6
sys.stdout.write(d[p:p+c2[5]].replace(b'\x00', b'|').decode('latin-1'))
PY
)"
        if [[ "$pool" == *"${oab}"* ]] && [[ "$pool" != *"${iab}"* ]]; then
            rm -f -- "$legacy"
            info "  removed 1.x leftover ${legacy}"
        else
            warn "  skipped /usr/local/share/zoneinfo/${src} (not a shim patch)"
        fi
    done < <(custom_zones_parse_file "$CONFIG_FILE")
    # Prune empty subdirs under /usr/local/share/zoneinfo if any exist
    if [[ -d /usr/local/share/zoneinfo/America ]] \
       && [[ -z "$(ls -A /usr/local/share/zoneinfo/America 2>/dev/null)" ]]; then
        rmdir /usr/local/share/zoneinfo/America 2>/dev/null || true
    fi
fi

# ============================================================================
# Prune empty Canadian/ namespace directory
# ============================================================================

if [[ -d "${ZONEINFO_DIR}/Canadian" ]] \
   && [[ -z "$(ls -A "${ZONEINFO_DIR}/Canadian" 2>/dev/null)" ]]; then
    rmdir "${ZONEINFO_DIR}/Canadian" 2>/dev/null || true
fi

# ============================================================================
# Remove state + config
# ============================================================================

if [[ -d "$STATE_DIR" ]]; then
    rm -rf -- "$STATE_DIR"
    info "Removed state directory: $STATE_DIR"
fi
if [[ -f "$CONFIG_PATH" ]]; then
    rm -f -- "$CONFIG_PATH"
    info "Removed config: $CONFIG_PATH"
fi

# Legacy config locations
for legacy in "${HOME}/.tzshim.conf" "${HOME}/.config/canadian-tz-shim.conf"; do
    [[ -f "$legacy" ]] && { rm -f "$legacy"; info "Removed legacy config: $legacy"; }
done

# Legacy user-level ~/.zoneinfo directory from pre-1.x releases
if [[ -d "${HOME}/.zoneinfo" ]]; then
    warn "Legacy directory ${HOME}/.zoneinfo still exists (from a very old shim)."
    warn "Not removed automatically. Delete manually if unneeded:"
    warn "  rm -rf ${HOME}/.zoneinfo"
fi

info "✓ Uninstallation complete."
echo ""

if [[ "$SCOPE" == "user" ]]; then
    echo "Remember to remove any TZ= export from your shell profile."
    echo ""
fi

if [[ "$restoration_failed" == "true" && "$FORCE" == "true" ]]; then
    warn "Note: /etc/localtime was not restored due to missing metadata."
    warn "You may need to set your timezone manually:"
    warn "  sudo ln -sf /usr/share/zoneinfo/YOUR_TIMEZONE /etc/localtime"
fi
