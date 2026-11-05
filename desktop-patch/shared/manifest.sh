#!/usr/bin/env bash
# Manifest management for desktop-patch
# Records all changes made by the utility for restoration

set -euo pipefail

# Utility version (must match main script)
DESKTOP_PATCH_VERSION="${DESKTOP_PATCH_VERSION:-1.0.0}"

# Initialize a new manifest
# Arguments: $1 = state directory, $2 = desktop, $3 = desktop version,
#            $4 = session type, $5 = timezone, $6 = backend
# Returns: path to manifest file on stdout
init_manifest() {
    local state_dir="$1"
    local desktop="$2"
    local desktop_version="$3"
    local session_type="$4"
    local timezone="$5"
    local backend="$6"
    
    mkdir -p "$state_dir"
    
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local manifest_id
    manifest_id=$(date +%s)-$$
    local manifest_file="${state_dir}/manifest-${manifest_id}.json"
    
    # Write manifest header as JSON
    cat > "$manifest_file" <<EOF
{
  "version": "${DESKTOP_PATCH_VERSION}",
  "manifest_id": "${manifest_id}",
  "timestamp": "${timestamp}",
  "desktop": "${desktop}",
  "desktop_version": "${desktop_version}",
  "session_type": "${session_type}",
  "timezone": "${timezone}",
  "backend": "${backend}",
  "changes": []
}
EOF
    
    echo "$manifest_file"
}

# Escape a string for safe JSON embedding
# Handles control characters, quotes, and backslashes
json_escape() {
    local s="$1"
    # Use Python for reliable JSON escaping
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read().rstrip('\n')))" <<< "$s"
}

# Add a change record to the manifest
# Arguments: $1 = manifest file, $2 = change type (file|schema|key)
#            $3 = target identifier, $4 = original value, $5 = new value
#            $6 = backup path (optional)
add_manifest_change() {
    local manifest="$1"
    local change_type="$2"
    local target="$3"
    local original_value="$4"
    local new_value="$5"
    local backup_path="${6:-}"
    
    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: Manifest not found: $manifest" >&2
        return 1
    fi
    
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Escape values for JSON safety
    local esc_target esc_original esc_new esc_backup
    esc_target=$(json_escape "$target")
    esc_original=$(json_escape "$original_value")
    esc_new=$(json_escape "$new_value")
    esc_backup=$(json_escape "$backup_path")
    
    # Build the change record
    local change_record
    change_record=$(cat <<EOF
    {
      "type": "${change_type}",
      "target": ${esc_target},
      "original_value": ${esc_original},
      "new_value": ${esc_new},
      "backup_path": ${esc_backup},
      "applied_at": "${timestamp}"
    }
EOF
)
    
    # Use Python to safely insert the record into the JSON array
    python3 - "$manifest" "$change_record" <<'PYEOF'
import json
import sys

manifest_path = sys.argv[1]
change_json = sys.argv[2]

try:
    with open(manifest_path, 'r') as f:
        data = json.load(f)
except (json.JSONDecodeError, IOError) as e:
    print(f"ERROR: Cannot read manifest: {e}", file=sys.stderr)
    sys.exit(1)

try:
    change = json.loads(change_json)
except json.JSONDecodeError as e:
    print(f"ERROR: Invalid change record: {e}", file=sys.stderr)
    sys.exit(1)

data['changes'].append(change)

with open(manifest_path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

# Finalize a manifest with verification result
# Arguments: $1 = manifest file, $2 = verification result (success|failed)
#            $3 = reload recommended (true|false), $4 = reload performed (true|false)
finalize_manifest() {
    local manifest="$1"
    local verification="$2"
    local reload_recommended="${3:-false}"
    local reload_performed="${4:-false}"
    
    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: Manifest not found: $manifest" >&2
        return 1
    fi
    
    python3 - "$manifest" "$verification" "$reload_recommended" "$reload_performed" <<'PYEOF'
import json
import sys

manifest_path = sys.argv[1]
verification = sys.argv[2]
reload_recommended = sys.argv[3] == 'true'
reload_performed = sys.argv[4] == 'true'

try:
    with open(manifest_path, 'r') as f:
        data = json.load(f)
except (json.JSONDecodeError, IOError) as e:
    print(f"ERROR: Cannot read manifest: {e}", file=sys.stderr)
    sys.exit(1)

data['verification'] = verification
data['reload_recommended'] = reload_recommended
data['reload_performed'] = reload_performed

with open(manifest_path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

# List all manifests for a desktop
# Arguments: $1 = state directory, $2 = desktop (optional, empty for all)
list_manifests() {
    local state_dir="$1"
    local desktop="${2:-}"
    
    if [[ ! -d "$state_dir" ]]; then
        return 0
    fi
    
    local pattern="manifest-*.json"
    if [[ -n "$desktop" ]]; then
        # Filter by desktop in the JSON content
        for f in "$state_dir"/$pattern; do
            [[ -f "$f" ]] || continue
            if python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
sys.exit(0 if d.get('desktop') == sys.argv[2] else 1)
" "$f" "$desktop" 2>/dev/null; then
                echo "$f"
            fi
        done
    else
        for f in "$state_dir"/$pattern; do
            [[ -f "$f" ]] && echo "$f"
        done
    fi
}

# Read a manifest file safely
# Arguments: $1 = manifest file
# Outputs the JSON content
read_manifest() {
    local manifest="$1"
    
    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: Manifest not found: $manifest" >&2
        return 1
    fi
    
    # Validate JSON
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$manifest" 2>/dev/null; then
        echo "ERROR: Invalid manifest JSON: $manifest" >&2
        return 1
    fi
    
    cat "$manifest"
}
