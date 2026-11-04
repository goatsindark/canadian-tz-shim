#!/usr/bin/env bash
# Canadian Timezone Shim - Release packaging
# Produces a clean, reproducible source archive containing everything needed
# to install, uninstall, upgrade and test - and nothing else.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(grep -oE 'CURRENT_VERSION="[^"]+"' install.sh | head -1 | cut -d'"' -f2)"
if [[ -z "$VERSION" ]]; then
    echo "ERROR: could not determine CURRENT_VERSION from install.sh" >&2
    exit 1
fi

NAME="canadian-tz-shim-${VERSION}"
OUT_DIR="${1:-dist}"
STAGING="${OUT_DIR}/${NAME}"

# Files required for installation, upgrade, uninstall and verification.
INCLUDE=(
    install.sh
    uninstall.sh
    zones.conf
    migrations.json
    LICENSE
    README.md
    IMPLEMENTATION.md
    UPGRADE_SYSTEM.md
    lib/patch_tzif.py
    lib/reapply.sh
    lib/upgrade.sh
    lib/canadian-tz-shim.service
    lib/canadian-tz-shim.path
    test.sh
    test-upgrade.sh
    test-uninstall-edge-cases.sh
    test-regressions.sh
    test-isolation.sh
    package-release.sh
)

# Explicitly never shipped: VCS data, scratch dirs, generated artifacts.
DENY_PATTERNS=(
    '.git'
    '.git/'
    'bin/'
    'docs/'
    '__pycache__'
    '*.pyc'
    '*.backup.*'
    '*.bak'
    '*.tmp'
    '.gitignore'
)

rm -rf "$STAGING"
mkdir -p "$STAGING/lib"

echo "Packaging ${NAME}"
echo

missing=0
for rel in "${INCLUDE[@]}"; do
    if [[ ! -f "$rel" ]]; then
        echo "  MISSING FROM SOURCE: $rel" >&2
        missing=1
        continue
    fi
    install -D -m 0644 "$rel" "${STAGING}/${rel}"
    echo "  + ${rel}"
done

if [[ "$missing" -ne 0 ]]; then
    echo "ERROR: include list references missing files" >&2
    rm -rf "$STAGING"
    exit 1
fi

# Restore executable bits for scripts
for f in install.sh uninstall.sh test.sh test-upgrade.sh test-uninstall-edge-cases.sh test-regressions.sh; do
    chmod 0755 "${STAGING}/${f}"
done
chmod 0755 "${STAGING}/lib/reapply.sh"

echo
echo "Verifying archive contents exclude denied patterns..."
violations=0
while IFS= read -r entry; do
    base="$(basename "$entry")"
    for pat in "${DENY_PATTERNS[@]}"; do
        case "$entry" in
            ./"${STAGING}"/*) : ;;
        esac
        case "$base" in
            $pat) echo "  VIOLATION: $entry matches $pat" >&2; violations=1 ;;
        esac
    done
done < <(cd "$STAGING" && find . -mindepth 1 | sed "s#^#./${STAGING}#" | grep -v "^$" || true)

if [[ "$violations" -ne 0 ]]; then
    echo "ERROR: denied content leaked into the archive" >&2
    rm -rf "$STAGING"
    exit 1
fi
echo "  clean"

# Deterministic metadata ordering and timestamps for reproducibility
if tar --help 2>&1 | grep -q -- '--sort'; then
    SORT_FLAGS=(--sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner)
else
    SORT_FLAGS=(--owner=0 --group=0 --numeric-owner)
fi

( cd "$OUT_DIR" && tar "${SORT_FLAGS[@]}" -czf "${NAME}.tar.gz" "${NAME}" )
( cd "$OUT_DIR" && zip -qr9 "${NAME}.zip" "${NAME}" -x '*.pyc' 2>/dev/null || \
    ( cd "$OUT_DIR" && tar rjf /dev/null 2>/dev/null; echo "(zip unavailable, tar.gz only)" ) )

echo
echo "Artifacts:"
ls -la "${OUT_DIR}/${NAME}.tar.gz"
echo
echo "SHA256:"
sha256sum "${OUT_DIR}/${NAME}.tar.gz"
echo
echo "Contents:"
tar tzf "${OUT_DIR}/${NAME}.tar.gz" | sort
