#!/usr/bin/env bash
# live-kde-verify.sh — run the full system-wide pipeline inside an
# unprivileged user mount namespace, then verify Qt 6 / Qt 5 resolution
# of Canadian/PCT against fixed dates.
#
# Never touches the developer's real /usr/share/zoneinfo, /etc/localtime,
# /var/lib, or KDE configuration.
#
# Exit 0 on success, 1 on failure, 2 if the environment can't run this.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; FAILED=1; }
info() { echo -e "${YELLOW}→${NC} $1"; }

FAILED=0

if ! command -v unshare >/dev/null 2>&1; then
    echo "unshare(1) not installed — cannot run" >&2; exit 2
fi
if ! command -v g++ >/dev/null 2>&1; then
    echo "g++ not installed — cannot build Qt probe" >&2; exit 2
fi

# Build the Qt probe in /tmp so it's visible to the mount namespace.
PROBE_CPP="${SCRIPT_DIR}/tools/tz_probe.cpp"
PROBE_BIN="$(mktemp -t tz_probe_XXXXXX)"
info "Building Qt probe..."
if pkg-config --exists Qt6Core 2>/dev/null; then
    g++ -std=c++17 -fPIC "$PROBE_CPP" -o "$PROBE_BIN" $(pkg-config --cflags --libs Qt6Core) || {
        echo "Qt6 build failed"; exit 2; }
elif pkg-config --exists Qt5Core 2>/dev/null; then
    g++ -std=c++11 -fPIC "$PROBE_CPP" -o "$PROBE_BIN" $(pkg-config --cflags --libs Qt5Core) || {
        echo "Qt5 build failed"; exit 2; }
else
    echo "Neither Qt5Core nor Qt6Core available via pkg-config" >&2; exit 2
fi
chmod +x "$PROBE_BIN"

# The inner script runs as fake-root inside a mount + user namespace.
INNER=$(cat <<'INNER_EOF'
set -e
export HOME=/root
export TZ=
mkdir -p /root

# Snapshot a writable copy of /usr/share/zoneinfo on tmpfs and bind over the real one.
mount -t tmpfs tmpfs /mnt
mkdir -p /mnt/zi /mnt/etc
cp -r /usr/share/zoneinfo/. /mnt/zi/
# Start the destination tree clean: drop any Canadian/* the host might already
# have (a previous real install would leave files without a matching manifest
# in the fresh tmpfs we mount over /var/lib).
rm -rf /mnt/zi/Canadian
mount --bind /mnt/zi /usr/share/zoneinfo

# Writable /var/lib for the shim's state
mount -t tmpfs tmpfs /var/lib
mkdir -p /var/lib/canadian-tz-shim

# Writable /etc so we can rewrite /etc/localtime
mkdir -p /mnt/etc /mnt/usr-local
cp -a /etc/. /mnt/etc/ 2>/dev/null || true
mount --bind /mnt/etc /etc

# Writable /usr/local for the systemd helper install (safe to skip in reality,
# but the installer does write there so we mirror it here)
mount --bind /mnt/usr-local /usr/local

# Set a clean starting state: /etc/localtime → America/Vancouver (unpatched)
rm -f /etc/localtime
ln -sf /usr/share/zoneinfo/America/Vancouver /etc/localtime

# Remove the config file if it's a stale copy (fresh install)
rm -f /etc/tzshim.conf

# --- pre-install state ---
echo "=== Before install ==="
echo "readlink /etc/localtime: $(readlink /etc/localtime)"
echo "TZ= date: $(env -u TZ date +'%Z %z')"

# --- run installer ---
echo ""
echo "=== Running install.sh (system scope) ==="
cd "__REPO__"
bash install.sh

echo ""
echo "=== Post-install state ==="
echo "readlink /etc/localtime: $(readlink /etc/localtime)"
echo "TZ= date +'%Z %z': $(env -u TZ date +'%Z %z')"

# Manifest present?
if [[ -f /var/lib/canadian-tz-shim/custom-zones.json ]]; then
    echo "manifest present with $(python3 -c "import json;d=json.load(open('/var/lib/canadian-tz-shim/custom-zones.json'));print(len(d['zones']))") entries"
else
    echo "MANIFEST MISSING"
fi

# --- Qt probe (this is what KDE's digital clock actually calls into) ---
echo ""
echo "=== Qt probe (fixed dates, matches Plasma 5/6 code path) ==="
PROBE="__PROBE__"
if [[ -x "$PROBE" ]]; then
    env -u TZ -u TZDIR "$PROBE"
    probe_rc=$?
    echo ""
    echo "probe_rc=$probe_rc"
    exit $probe_rc
else
    echo "Qt probe binary not visible in namespace: $PROBE"
    exit 3
fi
INNER_EOF
)

# Keep the probe on the shared /tmp so it's visible across the mount namespace
FIXED_PROBE="/tmp/tz_probe_$$_verify"
INNER="${INNER//__REPO__/${SCRIPT_DIR}}"
INNER="${INNER//__PROBE__/${FIXED_PROBE}}"

cp "$PROBE_BIN" "$FIXED_PROBE"
chmod 0755 "$FIXED_PROBE"

# Run inside unshare: --mount for private mount table, --user for unprivileged root,
# --map-root-user to appear as uid 0.
echo ""
echo "============================================"
echo "Canadian Timezone Shim — Live Qt/KDE verification"
echo "============================================"
echo ""

unshare --mount --user --map-root-user bash -c "$INNER" 2>&1 | tee /tmp/canada-verify-$$.log
rc=${PIPESTATUS[0]}

rm -f "$FIXED_PROBE" "$PROBE_BIN" /tmp/canada-verify-$$.log

echo ""
if [[ "$rc" == "0" ]]; then
    pass "Full system-scope pipeline + Qt probe all green"
    exit 0
else
    fail "Namespace verification returned rc=$rc"
    exit 1
fi
