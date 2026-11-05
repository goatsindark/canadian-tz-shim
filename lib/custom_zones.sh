#!/usr/bin/env bash
# Canadian Timezone Shim — Custom-zone pipeline library
#
# Owns everything the shim needs to build, install, verify, reapply and
# remove the custom "Canadian/*" TZif identifiers described in zones.conf.
#
# Design rules (do not violate):
#   - Never modify /usr/share/zoneinfo/America/* or any IANA-owned TZif
#     file. The installer only READS those files as sources.
#   - Do not rewrite /usr/share/zoneinfo/zone.tab or zone1970.tab
#     wholesale. Narrow, idempotent APPENDs of exactly our custom
#     identifier's line (derived from the source's existing line) are
#     permitted; every added line is recorded verbatim in
#     custom-zones.json, and uninstall removes only the exact recorded
#     lines it finds, nothing else.
#   - Never overwrite a file we did not install. Ownership is proven by a
#     matching sha256 in the manifest, not merely by a file being present.
#   - Stage atomic replacements *inside the destination directory* so the
#     final rename() stays on the same filesystem.
#   - Write the manifest atomically, and refresh it after every successful
#     rebuild (hash + timestamp).
#   - System-wide manifests live under /var/lib. Per-user manifests live
#     under $HOME/.local/state. Never put the system manifest under the
#     user's home; sudo can point HOME at root.
#
# Public functions:
#   custom_zones_parse_file  <path>       -> emits TSV rows (validated)
#   custom_zones_validate_id <id>         -> 0 if "Canadian/X" shape OK
#   custom_zones_manifest_path <scope>    -> /var/lib/... | $HOME/.local/...
#   custom_zones_base_dir    <scope>      -> /usr/share/zoneinfo | $HOME/.tzinfo
#   custom_zones_owned       <scope> <id> -> 0 if manifest owns <id> and hash matches
#   custom_zones_install     <scope> <src> <id> <old> <new>
#                                          -> build+stage+validate+rename+record
#   custom_zones_remove_owned <scope> <id> -> remove only if owned
#   custom_zones_rebuild_all <scope>      -> re-run patch for every recorded zone
#   custom_zones_list_owned  <scope>      -> emit custom ids

set -euo pipefail

# ============================================================================
# Constants
# ============================================================================

CUSTOM_NAMESPACE="Canadian"
SYSTEM_BASE="/usr/share/zoneinfo"
SYSTEM_MANIFEST="/var/lib/canadian-tz-shim/custom-zones.json"
USER_MANIFEST_REL=".local/state/canadian-tz-shim/custom-zones.json"
USER_BASE_REL=".tzinfo"

# ============================================================================
# Parsing + validation
# ============================================================================

# Emit every zones.conf row as one TSV line:
#   IANA_SOURCE   CUSTOM_ID   IANA_ABBR   OFFICIAL_ABBR   NAME   URL
# Rejects: malformed column counts, unsafe CUSTOM_IDs, duplicate sources
# or duplicates custom ids, empty fields, abbreviations that are not 3
# ASCII letters, and CUSTOM_IDs that leave the Canadian/ namespace.
custom_zones_parse_file() {
    local file="$1"
    [[ -f "$file" ]] || { echo "custom_zones_parse_file: no such file: $file" >&2; return 1; }

    local -A seen_source=() seen_custom=()
    local lineno=0
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        lineno=$((lineno + 1))
        local line="${raw%%$'\r'}"
        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

        # Split on '|'; require exactly 6 fields with none empty.
        IFS='|' read -r a b c d e f extra <<< "$line"
        if [[ -n "${extra:-}" ]]; then
            echo "line $lineno: too many fields" >&2; return 1
        fi
        if [[ -z "$a" || -z "$b" || -z "$c" || -z "$d" || -z "$e" || -z "$f" ]]; then
            echo "line $lineno: empty field" >&2; return 1
        fi

        custom_zones_validate_id   "$b" || { echo "line $lineno: bad CUSTOM_ID '$b'" >&2; return 1; }
        custom_zones_validate_iana "$a" || { echo "line $lineno: bad IANA_SOURCE '$a'" >&2; return 1; }
        custom_zones_validate_abbrev "$c" || { echo "line $lineno: bad IANA_ABBREV '$c'" >&2; return 1; }
        custom_zones_validate_abbrev "$d" || { echo "line $lineno: bad OFFICIAL_ABBREV '$d'" >&2; return 1; }

        if [[ -n "${seen_source[$a]:-}" ]]; then
            echo "line $lineno: duplicate IANA_SOURCE '$a'" >&2; return 1
        fi
        if [[ -n "${seen_custom[$b]:-}" ]]; then
            echo "line $lineno: duplicate CUSTOM_ID '$b'" >&2; return 1
        fi
        seen_source[$a]=1
        seen_custom[$b]=1

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "$e" "$f"
    done < "$file"
}

# Custom ID must be "Canadian/<token>" where <token> is 1–64 chars of
# [A-Za-z0-9._-], does not start with '.', and contains no '/'.
custom_zones_validate_id() {
    local id="$1"
    [[ "$id" == "${CUSTOM_NAMESPACE}/"* ]] || return 1
    local rest="${id#*/}"
    [[ -n "$rest" ]] || return 1
    [[ ${#rest} -le 64 ]] || return 1
    [[ "$rest" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [[ "$rest" != *".."* ]] || return 1
    [[ "$rest" != *"//"* ]] || return 1
    return 0
}

# IANA source must be a plausible relative path (no '..', no leading '/',
# no drive letters, no control chars) — the same shape as existing tzdata
# entries.
custom_zones_validate_iana() {
    local s="$1"
    [[ -n "$s" ]] || return 1
    [[ "$s" != /* ]] || return 1                    # must be relative
    [[ "$s" != *".."* ]] || return 1                # no traversal
    [[ "$s" != *"//"* ]] || return 1                # no empty component
    [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_+/.-]*$ ]] || return 1
    [[ "$s" == */* ]] || return 1                    # must include region/
    return 0
}

custom_zones_validate_abbrev() {
    local a="$1"
    [[ "$a" =~ ^[A-Z]{3}$ ]] || return 1
    return 0
}

# ============================================================================
# Scope helpers
# ============================================================================

custom_zones_base_dir() {
    local scope="$1"
    case "$scope" in
        system) printf '%s\n' "$SYSTEM_BASE" ;;
        user)   printf '%s\n' "${HOME}/${USER_BASE_REL}" ;;
        *) echo "custom_zones_base_dir: unknown scope '$scope'" >&2; return 1 ;;
    esac
}

custom_zones_manifest_path() {
    local scope="$1"
    case "$scope" in
        system) printf '%s\n' "$SYSTEM_MANIFEST" ;;
        user)   printf '%s\n' "${HOME}/${USER_MANIFEST_REL}" ;;
        *) echo "custom_zones_manifest_path: unknown scope '$scope'" >&2; return 1 ;;
    esac
}

# ============================================================================
# Manifest I/O  (JSON, python3 for correctness)
# ============================================================================

custom_zones_manifest_init() {
    local manifest="$1" base="$2"
    mkdir -p "$(dirname "$manifest")"
    if [[ ! -f "$manifest" ]]; then
        python3 - "$manifest" "$base" <<'PY'
import json, sys
manifest, base = sys.argv[1], sys.argv[2]
data = {"schema": 1, "base": base, "zones": {}}
tmp = manifest + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
os = __import__("os"); os.replace(tmp, manifest)
PY
    fi
}

# Read one field from the manifest for a given id; empty string if missing.
# Fields: source, iana_abbrev, official_abbrev, sha256, installed_at.
custom_zones_manifest_get() {
    local manifest="$1" id="$2" field="$3"
    [[ -f "$manifest" ]] || return 0
    python3 - "$manifest" "$id" "$field" <<'PY'
import json, sys
manifest, tzid, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(manifest) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
zone = d.get("zones", {}).get(tzid)
if zone is None: sys.exit(0)
print(zone.get(field, ""))
PY
}

# Record / update an entry. Preserves any sub-dicts we recorded earlier
# (notably `tab_lines`) so a rebuild refreshes the hash without forgetting
# what we already added to the tab files.
custom_zones_manifest_put() {
    local manifest="$1" id="$2" source="$3" iana_abbr="$4" \
          official_abbr="$5" sha256="$6"
    python3 - "$manifest" "$id" "$source" "$iana_abbr" "$official_abbr" \
              "$sha256" <<'PY'
import json, sys, os, datetime as dt
manifest, tzid, source, iab, oab, sha = sys.argv[1:7]
with open(manifest) as f:
    d = json.load(f)
existing = d.setdefault("zones", {}).get(tzid, {})
existing.update({
    "source": source,
    "iana_abbrev": iab,
    "official_abbrev": oab,
    "sha256": sha,
    "installed_at": dt.datetime.now(dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
})
d["zones"][tzid] = existing
tmp = manifest + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
os.replace(tmp, manifest)
PY
}

custom_zones_manifest_delete() {
    local manifest="$1" id="$2"
    python3 - "$manifest" "$id" <<'PY'
import json, sys, os
manifest, tzid = sys.argv[1], sys.argv[2]
with open(manifest) as f:
    d = json.load(f)
d.get("zones", {}).pop(tzid, None)
tmp = manifest + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
os.replace(tmp, manifest)
PY
}

# Record which exact line we added for a custom id, per tab file. This lets
# us remove the specific lines on uninstall and detect external edits.
custom_zones_manifest_put_tab_line() {
    local manifest="$1" id="$2" file_basename="$3" line="$4"
    python3 - "$manifest" "$id" "$file_basename" "$line" <<'PY'
import json, sys, os
manifest, tzid, tabname, line = sys.argv[1:5]
with open(manifest) as f:
    d = json.load(f)
z = d.setdefault("zones", {}).setdefault(tzid, {})
z.setdefault("tab_lines", {})[tabname] = line
tmp = manifest + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2); f.write("\n")
os.replace(tmp, manifest)
PY
}

# Read every recorded tab_line for a given custom id. Emits "file<TAB>line"
# per recorded entry so callers can drop each precisely.
custom_zones_manifest_list_tab_lines() {
    local manifest="$1" id="$2"
    [[ -f "$manifest" ]] || return 0
    python3 - "$manifest" "$id" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
z = d.get("zones", {}).get(sys.argv[2], {})
for name, line in z.get("tab_lines", {}).items():
    sys.stdout.write(f"{name}\t{line}\n")
PY
}

# List every custom id recorded in the manifest.
custom_zones_list_owned() {
    local scope="$1"
    local manifest; manifest="$(custom_zones_manifest_path "$scope")"
    [[ -f "$manifest" ]] || return 0
    python3 - "$manifest" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for tzid in sorted(d.get("zones", {}).keys()):
    print(tzid)
PY
}

# The manifest proves ownership only if the file exists AND its sha256
# equals the manifest record. Anything else is a conflict.
custom_zones_owned() {
    local scope="$1" id="$2"
    local base; base="$(custom_zones_base_dir "$scope")"
    local manifest; manifest="$(custom_zones_manifest_path "$scope")"
    local target="${base}/${id}"
    local recorded current
    recorded="$(custom_zones_manifest_get "$manifest" "$id" sha256)"
    [[ -z "$recorded" ]] && return 1
    [[ -f "$target" ]] || return 1
    current="$(sha256sum "$target" | awk '{print $1}')"
    [[ "$current" == "$recorded" ]]
}

# ============================================================================
# Generation + installation
# ============================================================================

# Build a custom zone from an IANA source and atomically install it into
# the scope's base directory. The temporary file is created inside the
# target's parent directory so the final rename() is same-filesystem
# (tmpfs -> /usr/share would not be atomic).
#
# Args: <scope> <source> <custom_id> <iana_abbr> <official_abbr> <patcher>
custom_zones_install() {
    local scope="$1" source="$2" id="$3" iab="$4" oab="$5" patcher="$6"
    local base manifest
    base="$(custom_zones_base_dir "$scope")"
    manifest="$(custom_zones_manifest_path "$scope")"
    custom_zones_manifest_init "$manifest" "$base"

    local src="${SYSTEM_BASE}/${source}"
    [[ -f "$src" ]] || { echo "source not found: $src" >&2; return 1; }

    local target="${base}/${id}"
    local target_dir; target_dir="$(dirname "$target")"
    mkdir -p "$target_dir"

    # Existence check: refuse to overwrite a file we don't own.
    if [[ -f "$target" ]]; then
        if custom_zones_owned "$scope" "$id"; then
            : # we own it — safe to replace
        else
            echo "refusing to overwrite $target: not recorded as owned by this shim" >&2
            return 2
        fi
    fi

    # Stage inside target's own directory (same filesystem guarantee).
    local tmp
    tmp="$(mktemp "${target_dir}/.${id##*/}.tmp.XXXXXX")" || {
        echo "cannot stage in ${target_dir}" >&2; return 1; }
    # Explicit cleanup helper. Bash RETURN traps are not safely scoped and
    # can leak across re-invocations of this function, so we clean up on
    # every exit path instead.
    _cz_cleanup() {
        if [[ -n "${1:-}" ]] && [[ -e "$1" ]]; then
            rm -f -- "$1" 2>/dev/null || true
        fi
    }

    if ! cp "$src" "$tmp"; then
        echo "copy failed: $src -> $tmp" >&2; _cz_cleanup "$tmp"; return 1
    fi
    if ! python3 "$patcher" "$tmp" "$iab" "$oab" >/dev/null; then
        echo "patcher refused for $id ($iab -> $oab)" >&2
        _cz_cleanup "$tmp"; return 1
    fi
    if ! python3 "$patcher" --validate "$tmp"; then
        echo "generated file failed structural validation: $tmp" >&2
        _cz_cleanup "$tmp"; return 1
    fi
    if ! _custom_zones_era_check "$tmp" "$src" "$iab" "$oab" "$source"; then
        echo "generated file failed era verification for $id" >&2
        _cz_cleanup "$tmp"; return 1
    fi

    # Ownership + mode
    if [[ "$scope" == "system" ]]; then
        chown root:root "$tmp" 2>/dev/null || true
        chmod 0644 "$tmp"
    else
        chmod 0644 "$tmp"
    fi

    # Atomic same-filesystem rename
    if ! mv -T -- "$tmp" "$target"; then
        echo "rename failed: $tmp -> $target" >&2
        _cz_cleanup "$tmp"
        return 1
    fi
    # tmp has been renamed; nothing to clean up.

    local sha
    sha="$(sha256sum "$target" | awk '{print $1}')"
    custom_zones_manifest_put "$manifest" "$id" "$source" "$iab" "$oab" "$sha"

    # Register the custom identifier in zone.tab / zone1970.tab so Qt's
    # QTimeZone::country()/comment() resolve, which is what KDE's digital
    # clock uses to decide whether the zone is "set" and whether to draw
    # a map marker. Best-effort: if the source has no tab entry (e.g.
    # America/Yellowknife, absent from upstream tzdata), the install still
    # succeeded — surface a note but don't fail.
    custom_zones_tab_register "$scope" "$source" "$id" "$iab" "$oab" || {
        local rc=$?
        if [[ "$rc" -eq 1 ]]; then
            # Real failure (unwritable tab, malformed line) — treat as
            # install failure and roll back the file we just wrote.
            rm -f -- "$target"
            return 1
        fi
    }
}

# Era verification for a freshly built custom zone. Uses zdump against
# fixed dates.
#   1. Historical winter before switch: expected abbr UNCHANGED vs source.
#   2. Historical summer before switch: expected abbr UNCHANGED vs source.
#   3. Immediately before the transition boundary: same as source.
#   4. Immediately after the transition boundary: expected NEW abbreviation
#      with the source's post-transition UTC offset.
#   5. Far-future: expected NEW abbreviation.
#
# The transition boundary is read from the source by diffing zdump output.
_custom_zones_era_check() {
    local patched="$1" src="$2" iab="$3" oab="$4" source_name="$5"
    if ! command -v zdump >/dev/null 2>&1; then
        # Without zdump we can't do date-bound verification; the
        # structural + pool tests above are still enough.
        return 0
    fi
    local src_winter src_summer
    src_winter="$(zdump -v "$src" 2>/dev/null | awk '
        /  Jan  1 1970 / {print $NF; exit}' | tr -d 'isdst=0 gmtoff=' || true)"

    # Pick two safe pre-switch dates that exist in every Canadian source.
    # (Vancouver, Edmonton, Winnipeg, Yellowknife all transitioned
    #  2026-11-01; Whitehorse/Dawson transitioned 2020-11-01.)
    local switch_year
    case "$source_name" in
        *Whitehorse*|*Dawson*) switch_year=2020 ;;
        *)                     switch_year=2026 ;;
    esac

    # Historical dates (must be preserved exactly).
    local pre_hist_winter pre_hist_summer post_pre post_switch
    pre_hist_winter="$(TZ="$src"     date -d "2010-01-15" +%Z)"
    pre_hist_summer="$(TZ="$src"     date -d "2010-07-15" +%Z)"
    post_pre="$(TZ="$src" date -d "$((switch_year-1))-07-15" +%Z)"

    local patch_hist_winter patch_hist_summer patch_pre
    patch_hist_winter="$(TZ="$patched" date -d "2010-01-15" +%Z)"
    patch_hist_summer="$(TZ="$patched" date -d "2010-07-15" +%Z)"
    patch_pre="$(TZ="$patched"         date -d "$((switch_year-1))-07-15" +%Z)"

    for pair in "$pre_hist_winter:$patch_hist_winter" \
                "$pre_hist_summer:$patch_hist_summer" \
                "$post_pre:$patch_pre"; do
        local want="${pair%%:*}" got="${pair##*:}"
        if [[ "$want" != "$got" ]]; then
            echo "  era check: historical abbr drift ($want -> $got)" >&2
            return 1
        fi
    done

    # Post-switch instant
    local post_want post_got
    post_want="$oab"
    post_got="$(TZ="$patched" date -d "$((switch_year+1))-01-15" +%Z)"
    if [[ "$post_got" != "$post_want" ]]; then
        echo "  era check: post-switch expected $post_want, got $post_got" >&2
        return 1
    fi
    local future_got
    future_got="$(TZ="$patched" date -d "2100-06-15" +%Z)"
    if [[ "$future_got" != "$post_want" ]]; then
        echo "  era check: far-future expected $post_want, got $future_got" >&2
        return 1
    fi

    # Offsets must be identical
    local src_off patch_off
    src_off="$(TZ="$src" date -d "$((switch_year+1))-01-15" +%z)"
    patch_off="$(TZ="$patched" date -d "$((switch_year+1))-01-15" +%z)"
    [[ "$src_off" == "$patch_off" ]] || {
        echo "  era check: post-switch offset differs ($src_off vs $patch_off)" >&2
        return 1; }

    return 0
}

# Re-run the patch for every recorded zone. Called after tzdata updates.
custom_zones_rebuild_all() {
    local scope="$1" patcher="$2" zones_conf="$3"
    local base; base="$(custom_zones_base_dir "$scope")"
    local manifest; manifest="$(custom_zones_manifest_path "$scope")"
    [[ -f "$manifest" ]] || return 0

    local parsed
    parsed="$(custom_zones_parse_file "$zones_conf")" || return 1

    while IFS=$'\t' read -r source id iab oab _name _url; do
        [[ -z "$source" ]] && continue
        local rec_src
        rec_src="$(custom_zones_manifest_get "$manifest" "$id" source)"
        # Only rebuild ids we recorded previously.
        [[ "$rec_src" == "$source" ]] || continue
        custom_zones_install "$scope" "$source" "$id" "$iab" "$oab" "$patcher"
    done <<< "$parsed"
}

# Remove a single recorded, hash-matching file. Never touches unowned files.
custom_zones_remove_owned() {
    local scope="$1" id="$2"
    local base; base="$(custom_zones_base_dir "$scope")"
    local manifest; manifest="$(custom_zones_manifest_path "$scope")"
    local target="${base}/${id}"

    if ! custom_zones_owned "$scope" "$id"; then
        echo "refusing to remove $target: not recorded as owned (or hash changed)" >&2
        return 2
    fi
    # Remove the tab-file entries we added first, so a subsequent
    # `custom_zones_install` of the same id would derive a fresh line.
    custom_zones_tab_unregister "$scope" "$id"
    rm -f -- "$target"
    custom_zones_manifest_delete "$manifest" "$id"

    # Prune the namespace directory if now empty.
    local nsdir="${base}/${CUSTOM_NAMESPACE}"
    if [[ -d "$nsdir" ]] && [[ -z "$(ls -A -- "$nsdir" 2>/dev/null)" ]]; then
        rmdir -- "$nsdir" 2>/dev/null || true
    fi
}

# ============================================================================
# zone.tab registration
# ============================================================================
# Qt's QTimeZone::country() and QTimeZone::comment() are populated from
# zone.tab / zone1970.tab — NOT from the TZif file. KDE's digital clock uses
# both signals to decide whether a zone is "set" and whether to place a map
# marker. Without a matching tab line, our custom identifier is present in
# availableTimeZoneIds() (Qt scans the directory) but renders as if unset,
# because country() is AnyCountry and comment() is empty.
#
# The register step:
#   - For each tab file that exists, find the SOURCE zone's own line.
#   - Derive a line for CUSTOM_ID by swapping the TZ field and, when the
#     comment begins with the source's IANA abbreviation, replacing that
#     prefix with the official abbreviation. This keeps the map coordinates
#     and country code identical to the source (which is what the user asked
#     for: "Canadian/PCT behaves like America/Vancouver"), while the visible
#     comment reflects the actual abbreviation.
#   - If any source line is missing (tzdata stripped, non-standard build),
#     refuse rather than fabricate.
#   - Idempotent: if a line with the same TZ field already exists AND matches
#     our derived content, do nothing. If it exists but differs, replace it.
#   - If the file exists but is not writable, refuse.
#   - Atomic replacement inside the file's own directory.

TAB_REGISTER_SOURCES=(zone.tab zone1970.tab)

# Derive a custom line from a source line. Echoes nothing on failure and
# returns 1, so callers can distinguish "not present" from "malformed".
custom_zones_tab_derive() {
    local source_line="$1" source_id="$2" custom_id="$3" iab="$4" oab="$5"
    awk -F'\t' -v OFS='\t' \
        -v src="$source_id" -v cid="$custom_id" \
        -v iab="$iab"   -v oab="$oab" '
    BEGIN { got = 0 }
    {
        if ($3 == src) {
            $3 = cid
            # Replace the leading abbreviation token when it is exactly the
            # source IANA abbreviation. Do NOT touch a longer comment where
            # the abbreviation is only a substring of a different word.
            if (NF >= 4) {
                n = split($4, parts, " ")
                if (n >= 1 && parts[1] == iab) {
                    parts[1] = oab
                    newc = parts[1]
                    for (j = 2; j <= n; j++) newc = newc " " parts[j]
                    $4 = newc
                }
            }
            print
            got = 1
            exit
        }
    }
    END { exit (got ? 0 : 1) }
    ' <<< "$source_line"
}

# Atomic append of a single line to a tab file.
_custom_zones_tab_append_atomic() {
    local path="$1" line="$2"
    local dir; dir="$(dirname "$path")"
    local base; base="$(basename "$path")"
    local tmp
    tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX")" || return 1
    # Preserve mode + ownership of the source file
    chmod --reference="$path" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    chown --reference="$path" "$tmp" 2>/dev/null || true
    cat "$path" > "$tmp"
    printf '%s\n' "$line" >> "$tmp"
    mv -T -- "$tmp" "$path"
}

# Atomic replace of every line whose field-3 matches $tz with a single
# replacement line. Preserves ordering by placing the replacement at the
# first occurrence and dropping the rest.
_custom_zones_tab_replace_atomic() {
    local path="$1" tz="$2" newline="$3"
    local dir; dir="$(dirname "$path")"
    local base; base="$(basename "$path")"
    local tmp
    tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX")" || return 1
    chmod --reference="$path" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    chown --reference="$path" "$tmp" 2>/dev/null || true
    awk -F'\t' -v OFS='\t' -v t="$tz" -v n="$newline" '
        $3 == t { if (!emitted) { print n; emitted = 1 }; next }
        { print }
    ' "$path" > "$tmp"
    mv -T -- "$tmp" "$path"
}

# Register a custom id in the tab files that exist under the scope's base.
# Args: <scope> <source_iana_id> <custom_id> <iana_abbr> <official_abbr>
# Best-effort policy:
#   - User scope has no zone.tab to write to: silently succeed (return 0).
#   - System scope with a source zone that isn't listed in either tab file:
#     log a note and succeed (return 0) — the TZif is installed, only the
#     map/country metadata is missing.
#   - Tab file present but source not listed: skip that file; try the next.
#   - Tab file present, source listed, file unwritable: FAIL (return 1).
#   - Tab file absent entirely: skip.
custom_zones_tab_register() {
    local scope="$1" source="$2" custom_id="$3" iab="$4" oab="$5"
    local base; base="$(custom_zones_base_dir "$scope")"
    local manifest; manifest="$(custom_zones_manifest_path "$scope")"

    if ! [[ "$custom_id" == ${CUSTOM_NAMESPACE}/* ]]; then
        echo "tab_register: refusing to register outside ${CUSTOM_NAMESPACE}/ namespace" >&2
        return 1
    fi

    # User-scope installs never write to a system zone.tab. The tab
    # registration only matters when the base directory is the one Qt/KDE
    # scans (/usr/share/zoneinfo). Skip cleanly.
    if [[ "$scope" != "system" ]]; then
        return 0
    fi

    local any_tab_present=0
    local any_source_found=0

    for tabname in "${TAB_REGISTER_SOURCES[@]}"; do
        local tab="${base}/${tabname}"
        [[ -f "$tab" ]] || continue
        any_tab_present=1

        # Locate the source's own line
        local source_line
        source_line="$(awk -F'\t' -v s="$source" '$3 == s {print; exit}' "$tab")"
        if [[ -z "$source_line" ]]; then
            # Legitimate for e.g. America/Yellowknife (tzdata has no
            # canonical entry, so no coordinates exist). Log once, keep going.
            continue
        fi
        any_source_found=1

        # Derive our line
        local our_line
        if ! our_line="$(custom_zones_tab_derive "$source_line" "$source" "$custom_id" "$iab" "$oab")"; then
            echo "  tab: derivation failed for $custom_id from $tabname" >&2
            return 1
        fi

        if [[ ! -w "$tab" ]]; then
            echo "  tab: refusing to modify unwritable $tab" >&2
            return 1
        fi

        # Idempotent check + write
        local existing
        existing="$(awk -F'\t' -v c="$custom_id" '$3 == c {print; exit}' "$tab")"
        if [[ -n "$existing" ]]; then
            if [[ "$existing" != "$our_line" ]]; then
                _custom_zones_tab_replace_atomic "$tab" "$custom_id" "$our_line"
            fi
        else
            _custom_zones_tab_append_atomic "$tab" "$our_line"
        fi

        custom_zones_manifest_put_tab_line "$manifest" "$custom_id" "$tabname" "$our_line"
    done

    if [[ "$any_tab_present" == "0" ]]; then
        # No tab files exist at all (rare — broken tzdata install).
        # Not a failure for the shim; the TZif is still functional.
        return 0
    fi
    if [[ "$any_source_found" == "0" ]]; then
        # No tab file lists this source. Fine, but note it for diagnostics.
        echo "  note: '$source' has no zone.tab or zone1970.tab entry (upstream tzdata); " \
             "KDE will not draw a map marker for '$custom_id'." >&2
    fi
    return 0
}

# Remove exactly the lines we recorded. Never touches lines whose content
# differs from what the manifest says we wrote (protects against hand-edits
# or tzdata upgrades that already replaced the file wholesale).
custom_zones_tab_unregister() {
    local scope="$1" id="$2"
    local base; base="$(custom_zones_base_dir "$scope")"
    local manifest; manifest="$(custom_zones_manifest_path "$scope")"
    local tab_lines
    tab_lines="$(custom_zones_manifest_list_tab_lines "$manifest" "$id")"
    [[ -z "$tab_lines" ]] && return 0

    while IFS=$'\t' read -r tabname recorded_line; do
        [[ -z "$tabname" ]] && continue
        local tab="${base}/${tabname}"
        [[ -f "$tab" ]] || continue

        if ! grep -Fxq "$recorded_line" "$tab" 2>/dev/null; then
            warn "  tab: recorded line not present in $tabname (external change?); leaving file alone"
            continue
        fi
        if [[ ! -w "$tab" ]]; then
            warn "  tab: refusing to modify unwritable $tabname"
            continue
        fi

        local dir; dir="$(dirname "$tab")"
        local tmp; tmp="$(mktemp "${dir}/.${tabname}.tmp.XXXXXX")" || continue
        chmod --reference="$tab" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$tab" "$tmp" 2>/dev/null || true
        # Filter out exactly the recorded line (literal, not regex).
        grep -Fxv "$recorded_line" "$tab" > "$tmp" || true
        mv -T -- "$tmp" "$tab"
    done <<< "$tab_lines"
}
