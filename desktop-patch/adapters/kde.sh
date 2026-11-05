#!/usr/bin/env bash
# KDE Plasma adapter for desktop-patch (v2 — Canada namespace, minimal scope)
#
# This adapter ONLY rewrites an explicit `America/<Canadian>` identifier
# inside an org.kde.plasma.digitalclock applet config so that it points at
# the matching custom `Canadian/*` identifier. The custom zone file must
# already exist and be discoverable to Qt — this adapter NEVER generates
# one.
#
# If the applet is set to `Local` (or does not have an explicit Canadian
# source id), the adapter reports "no change needed" and writes nothing,
# because /etc/localtime already governs the display once the core
# installer has repointed it.

set -euo pipefail

KDE_ADAPTER_NAME="kde"
KDE_ADAPTER_DISPLAY="KDE Plasma"
KDE_ADAPTER_BACKEND="kconfig"

# The zone map we care about (source → custom). Populated from zones.conf
# via the custom_zones library.
_kde_custom_map=""

# Read source→custom map from zones.conf, lazily.
_kde_load_map() {
    [[ -n "$_kde_custom_map" ]] && return 0
    if ! command -v custom_zones_parse_file >/dev/null 2>&1; then
        echo "custom_zones library not loaded — cannot resolve mapping" >&2
        return 1
    fi
    _kde_custom_map="$(custom_zones_parse_file "$DESKTOP_PATCH_ZONES_CONF")"
}

# Detect KDE Plasma
kde_detect() {
    local xdg="${XDG_CURRENT_DESKTOP:-}"
    local sess="${XDG_SESSION_DESKTOP:-}"
    local dsess="${DESKTOP_SESSION:-}"
    xdg="${xdg,,}"; sess="${sess,,}"; dsess="${dsess,,}"
    [[ "$xdg" == *"kde"* || "$sess" == *"kde"* || "$dsess" == *"kde"* ]]
}

# Locate every digitalclock applet's config section in the appletsrc file.
# Output is one "section_path<TAB>TimeZones_list" per clock applet.
# Handles Plasma 5 and Plasma 6, both of which use:
#   [Containments][<N>][Applets][<M>]
#     plugin=org.kde.plasma.digitalclock
#   [Containments][<N>][Applets][<M>][Configuration]
#     selectedTimeZones=...
#     fixedTimeZones=...
#     TimeZone=...    (Plasma 5 sometimes uses TimeZoneId)
_kde_list_clock_applets() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 1

    # Pass 1: locate every Applets section whose plugin=digitalclock.
    # Plasma's section headers look like:
    #   [Containments][1][Applets][2]
    #   [Containments][1][Applets][2][Configuration]
    # We preserve the outer brackets so Pass 2 can match section headers
    # literally.
    local cur_path=""
    local -a clock_paths=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in \#*) continue ;; esac
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            cur_path="$line"
        elif [[ "$line" == "plugin=org.kde.plasma.digitalclock" ]]; then
            # Trim off the trailing "[Applets][N]..."; keep up to and including the N.
            # The plugin line lives inside the Applets section itself.
            if [[ "$cur_path" =~ ^(\[.*\[Applets\]\[[0-9]+\])$ ]]; then
                local applet_path="${BASH_REMATCH[1]}"
                case " ${clock_paths[*]-} " in
                    *" $applet_path "*) : ;;
                    *) clock_paths+=("$applet_path") ;;
                esac
            fi
        fi
    done < "$cfg"

    # Pass 2: for each clock applet, read its [Configuration] section keys.
    for p in "${clock_paths[@]-}"; do
        [[ -z "$p" ]] && continue
        local conf_path="${p}[Configuration]"
        local selected="" fixed="" tzid=""
        local in_section=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^\[.*\]$ ]]; then
                if [[ "$line" == "$conf_path" ]]; then
                    in_section=1
                else
                    [[ "$in_section" == "1" ]] && break
                fi
                continue
            fi
            if [[ "$in_section" == "1" ]]; then
                case "$line" in
                    selectedTimeZones=*) selected="${line#selectedTimeZones=}" ;;
                    fixedTimeZones=*)     fixed="${line#fixedTimeZones=}" ;;
                    TimeZoneId=*)         tzid="${line#TimeZoneId=}" ;;
                esac
            fi
        done < "$cfg"
        # Emit section header as-is (with brackets) so consumers match
        # file lines literally.
        printf '%s\t%s\t%s\t%s\n' "$p" "$selected" "$fixed" "$tzid"
    done
}

kde_inspect() {
    local cfg
    cfg="$(find_plasma_config)" || { echo "  Plasma appletsrc not found at ~/.config/"; return 1; }
    echo "  Applet config file: $cfg"
    echo ""
    echo "  digitalclock applets (path -> selectedTimeZones / TimeZoneId):"
    local n=0
    while IFS=$'\t' read -r path selected fixed tzid; do
        [[ -z "$path" ]] && continue
        n=$((n+1))
        echo "  [$n] $path"
        echo "      selectedTimeZones = $selected"
        [[ -n "$fixed" ]] && echo "      fixedTimeZones    = $fixed"
        [[ -n "$tzid"   ]] && echo "      TimeZoneId        = $tzid"
        # Look for a Canadian source anywhere in the selected list
        if _kde_load_map 2>/dev/null; then
            local found=""
            IFS=',' read -ra toks <<< "$selected${tzid:+,$tzid}"
            for t in "${toks[@]}"; do
                while IFS=$'\t' read -r src id _a _b _c _d; do
                    [[ "$src" == "$t" ]] && found="$t → $id"
                done <<< "$_kde_custom_map"
            done
            if [[ -n "$found" ]]; then
                echo "      ⚠ contains Canadian source: $found"
            fi
            # If it says "Local", /etc/localtime governs it.
            for t in "${toks[@]}"; do
                if [[ "$t" == "Local" ]]; then
                    echo "      ✓ contains 'Local' — already follows /etc/localtime"
                    break
                fi
            done
        fi
    done < <(_kde_list_clock_applets "$cfg")
    if [[ "$n" -eq 0 ]]; then
        echo "  (no digitalclock applets found)"
    fi
    return 0
}

kde_plan() {
    _kde_load_map || return 1
    local cfg; cfg="$(find_plasma_config)" || { echo "  no Plasma config found" >&2; return 1; }
    echo "Planned changes for KDE Plasma:"
    echo ""
    echo "  Source-of-truth file: $cfg"
    echo "  Custom identifier source: $DESKTOP_PATCH_ZONES_CONF"
    echo ""
    local any=0
    while IFS=$'\t' read -r path selected _fixed tzid; do
        [[ -z "$path" ]] && continue
        IFS=',' read -ra toks <<< "$selected"
        local repl=0
        local newlist=""
        for t in "${toks[@]}"; do
            local mapped=""
            while IFS=$'\t' read -r src id _a _b _c _d; do
                [[ "$src" == "$t" ]] && mapped="$id"
            done <<< "$_kde_custom_map"
            if [[ -n "$mapped" ]]; then
                newlist+="${newlist:+,}$mapped"; repl=$((repl+1))
            else
                newlist+="${newlist:+,}$t"
            fi
        done
        if [[ "$repl" -gt 0 ]]; then
            any=1
            echo "  applet $path:"
            echo "    selectedTimeZones: '$selected' → '$newlist'"
            # Custom availability check
            local missing=()
            for tok in ${newlist//,/ }; do
                case "$tok" in Canadian/*) [[ -f "/usr/share/zoneinfo/$tok" ]] || missing+=("$tok") ;; esac
            done
            if [[ ${#missing[@]} -gt 0 ]]; then
                echo "    ⚠ MISSING custom zones (run core installer first): ${missing[*]}"
            fi
        else
            # No explicit Canadian source id — likely "Local".
            local has_local=0
            for t in "${toks[@]}"; do [[ "$t" == "Local" ]] && has_local=1; done
            if [[ "$has_local" == "1" ]]; then
                echo "  applet $path: contains 'Local' → no change needed"
            fi
        fi
    done < <(_kde_list_clock_applets "$cfg")
    if [[ "$any" == "0" ]]; then
        echo ""
        echo "  No KDE configuration change required: every clock follows 'Local'."
        echo "  Once the core installer repoints /etc/localtime, the clock already"
        echo "  displays the Canadian abbreviation."
    fi
    return 0
}

kde_apply() {
    local _ignored="$1" _index="$2" state_dir="$3" dry_run="${4:-false}"
    _kde_load_map || return 1
    local cfg; cfg="$(find_plasma_config)" || { echo "  Plasma appletsrc not found" >&2; return 1; }

    local changed=0
    while IFS=$'\t' read -r path selected _fixed _tzid; do
        [[ -z "$path" ]] && continue
        IFS=',' read -ra toks <<< "$selected"
        local newlist="" mapped_any=0
        for t in "${toks[@]}"; do
            local mapped=""
            while IFS=$'\t' read -r src id _a _b _c _d; do
                [[ "$src" == "$t" ]] && mapped="$id" && mapped_any=1
            done <<< "$_kde_custom_map"
            newlist+="${newlist:+,}$mapped${mapped:+}${mapped:-$t}"
        done
        if [[ "$mapped_any" == "0" ]]; then
            continue   # this applet doesn't reference a Canadian source; skip
        fi
        changed=$((changed+1))

        if [[ "$dry_run" == "true" ]]; then
            echo "DRY RUN: would set ${path}[Configuration] selectedTimeZones = $newlist"
            continue
        fi

        # Verify all target custom ids exist (core installer must have run)
        for tok in ${newlist//,/ }; do
            if [[ "$tok" == Canadian/* && ! -f "/usr/share/zoneinfo/$tok" ]]; then
                echo "ERROR: custom zone '$tok' not installed. Run the core installer first." >&2
                return 1
            fi
        done

        # Back up and rewrite ONLY the selectedTimeZones line in that
        # [Configuration] section. Everything else is byte-preserved.
        local backup_dir; backup_dir="$(create_backup_directory "$state_dir" "kde")"
        local backup; backup="$(backup_file "$cfg" "$backup_dir")" || return 1
        local conf_section="${path}[Configuration]"   # already bracket-wrapped
        _kde_set_key "$cfg" "$conf_section" "selectedTimeZones" "$newlist" || {
            cp -- "$backup" "$cfg"
            return 1
        }

        # Manifest record
        local manifest
        manifest="$(init_manifest "$state_dir" "kde" "$(get_plasma_version)" \
            "${DETECTED_SESSION_TYPE:-}" "$newlist" "kconfig")"
        add_manifest_change "$manifest" "file" \
            "${cfg}::${conf_path}::selectedTimeZones" \
            "$selected" "$newlist" "$backup"
        finalize_manifest "$manifest" "success" "true" "false"

        echo "  Updated applet $path: selectedTimeZones=$newlist"
    done < <(_kde_list_clock_applets "$cfg")

    if [[ "$changed" == "0" ]]; then
        echo "  No applet required a change (either they use 'Local', or none stored a Canadian source id)."
        return 0
    fi
    echo ""
    echo "  Plasma does NOT need to restart for the change to be visible."
    echo "  The digitalclock reloads its config when plasmashell receives a KConfig"
    echo "  notification, and /etc/xdg/plasma-org.kde.plasma.desktop-appletsrc is"
    echo "  re-read on next panel edit. If the widget appears stale, log out and back"
    echo "  in (or run kquitapp5 plasmashell; kstart5 plasmashell)."
}

# Rewrite a single key/value inside one KConfig section, atomic replace.
# `section` must be the raw section header including brackets, e.g.
#   [Containments][1][Applets][2][Configuration]
_kde_set_key() {
    local cfg="$1" section="$2" key="$3" value="$4"
    local tmp="${cfg}.tmp.$$"
    local in_section=0 wrote=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            if [[ "$in_section" == "1" && "$wrote" == "0" ]]; then
                # We just left the target section without finding the key: insert.
                printf '%s=%s\n' "$key" "$value"
                wrote=1
            fi
            if [[ "$line" == "$section" ]]; then
                in_section=1
            else
                in_section=0
            fi
            printf '%s\n' "$line"
        elif [[ "$in_section" == "1" && "$line" == "${key}="* ]]; then
            printf '%s=%s\n' "$key" "$value"
            wrote=1
        else
            printf '%s\n' "$line"
        fi
    done < "$cfg" > "$tmp"
    if [[ "$wrote" == "0" ]]; then
        echo "  ERROR: section '$section' not found in $cfg" >&2
        rm -f "$tmp"; return 1
    fi
    mv -T -- "$tmp" "$cfg"
}

kde_verify() {
    local _ignored="$1"
    local cfg; cfg="$(find_plasma_config)" || return 1
    # Check every digitalclock applet's selectedTimeZones contains no Canadian source
    # id from zones.conf — either 'Local', 'Etc/UTC', or a 'Canadian/*' id.
    while IFS=$'\t' read -r path selected _f _t; do
        [[ -z "$path" ]] && continue
        IFS=',' read -ra toks <<< "$selected"
        for t in "${toks[@]}"; do
            while IFS=$'\t' read -r src _id _a _b _c _d; do
                [[ "$src" == "$t" ]] && { echo "  still points at source $t"; return 1; }
            done <<< "$_kde_custom_map"
        done
    done < <(_kde_list_clock_applets "$cfg")
    return 0
}

kde_restore() {
    local manifest="$1" _state="$2"
    [[ -f "$manifest" ]] || { echo "manifest missing" >&2; return 1; }
    local cfg; cfg="$(find_plasma_config)" || return 1
    python3 - "$manifest" <<'PY' | while IFS=$'\t' read -r conf_path key orig; do
import json, sys
d = json.load(open(sys.argv[1]))
for c in d.get("changes", []):
    if c.get("type") == "file" and c["target"].endswith("::selectedTimeZones"):
        parts = c["target"].split("::")
        print(f"{parts[1]}\t{parts[2]}\t{c['original_value']}")
PY
        _kde_set_key "$cfg" "$conf_path" "$key" "$orig"
        echo "  restored $key in $conf_path → $orig"
    done
    echo "  (verify no clock still references a Canadian source: kde_verify)"
}

kde_status() { kde_inspect; }
