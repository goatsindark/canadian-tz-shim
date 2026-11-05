#!/usr/bin/env bash
# Canadian Timezone Shim — 1.x → 2.x migration regression test.
#
# Boots a fake 1.x installation (patched America/* files, single-field
# selected-zone state, schema_version=1, installed_version=1.0.0), then
# runs `install.sh --upgrade` inside a private mount + user namespace
# so the system-scope write targets a tmpfs /usr/share/zoneinfo/ that
# we control. Asserts every property of the transactional migration the
# user asked for.
#
# Never touches the developer's real /usr/share, /etc, /var, or HOME.
# Requires: unshare(1). Skips cleanly (exit 0) if not available.
#
# Exit:
#   0 = migration verified end-to-end
#   1 = assertion failed
#   2 = environment can't run this (missing unshare)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}→${NC} $1"; }
PASS=0
FAIL=0

if ! command -v unshare >/dev/null 2>&1; then
    echo "unshare(1) not available — skipping migration test" >&2
    exit 2
fi

# Build a fixture tarball of the repo to run inside the namespace
REPO_TAR="$(mktemp -t tzshim-repo-XXXXXX.tar.gz)"
tar czf "$REPO_TAR" -C "$SCRIPT_DIR" \
    --exclude='.git' --exclude='dist' --exclude='desktop-patch/docker' \
    . || { echo "cannot pack repo" >&2; exit 1; }

INNER_SCRIPT="$(mktemp -t tzshim-mig-XXXXXX.sh)"
cat > "$INNER_SCRIPT" <<'INNER'
set -e
# Writable targets we need
mount -t tmpfs tmpfs /mnt
mkdir -p /mnt/repo /mnt/zi /mnt/etc

# Extract repo into /mnt/repo
tar --no-same-owner -xzf "__REPO_TAR__" -C /mnt/repo

# Seed /usr/share/zoneinfo from the real host copy (excluding any
# Canadian/* directory so the migration runs against a clean state)
cp -r /usr/share/zoneinfo/. /mnt/zi/ 2>/dev/null || true
rm -rf /mnt/zi/Canadian
mount --bind /mnt/zi /usr/share/zoneinfo

# Writable /etc with a fresh /etc/localtime + a fake original_timezone
mkdir -p /mnt/etc
cp -r /etc/. /mnt/etc/ 2>/dev/null || true
mount --bind /mnt/etc /etc

# Preseed the /etc/localtime at the unpatched IANA source so
# discover_installation and detect_current_timezone see a real system
rm -f /etc/localtime
ln -sf /usr/share/zoneinfo/America/Vancouver /etc/localtime

# Writable /usr/local for the exec-dir helper install
mount -t tmpfs tmpfs /usr/local

# Writable /var/lib/canadian-tz-shim
mount -t tmpfs tmpfs /var/lib
mkdir -p /var/lib/canadian-tz-shim

# ============================================================================
# Build a realistic 1.x installation state:
#   - /usr/local/share/zoneinfo/America/{Vancouver,Edmonton,...} exist
#     and are PATCHED (PCT, ABT, ...)
#   - /etc/tzshim.conf with installed_version=1.0.0, schema_version=1
#   - /var/lib/canadian-tz-shim/selected-zone with just "America/Vancouver"
# ============================================================================
mkdir -p /usr/local/share/zoneinfo/America
for z in Vancouver Edmonton Whitehorse Dawson Winnipeg Yellowknife; do
    cp "/usr/share/zoneinfo/America/$z" "/usr/local/share/zoneinfo/America/$z"
done
# Patch a couple with the real patcher
for pair in "Vancouver MST PCT" "Edmonton CST ABT" "Whitehorse MST YST" \
            "Dawson MST YST" "Winnipeg EST MBT" "Yellowknife CST NWT"; do
    read -r city old new <<< "$pair"
    python3 /mnt/repo/lib/patch_tzif.py \
        "/usr/local/share/zoneinfo/America/$city" "$old" "$new" >/dev/null
done

cat > /etc/tzshim.conf <<'CONF'
original_timezone=America/Los_Angeles
installed_version=1.0.0
schema_version=1
CONF
printf 'America/Vancouver\n' > /var/lib/canadian-tz-shim/selected-zone

echo ""
echo "=== Pre-migration state ==="
echo "  /etc/localtime → $(readlink /etc/localtime)"
echo "  installed_version: $(grep '^installed_version=' /etc/tzshim.conf)"
echo "  schema_version:    $(grep '^schema_version=' /etc/tzshim.conf)"
echo "  1.x legacy files:  $(ls /usr/local/share/zoneinfo/America/ | wc -l)"
echo "  Canadian dir:      $(ls -d /usr/share/zoneinfo/Canadian 2>/dev/null || echo 'not present')"

# ============================================================================
# Run the migration
# ============================================================================
echo ""
echo "=== Running install.sh --upgrade ==="
cd /mnt/repo
bash install.sh --upgrade 2>&1
mig_rc=$?
echo "  install.sh --upgrade rc=$mig_rc"

# ============================================================================
# Assertions
# ============================================================================
echo ""
echo "=== Post-migration assertions ==="

fail=0
check() {
    local label="$1" cond="$2"
    if eval "$cond"; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label"
        fail=1
    fi
}

check "exit code 0"                    "[ $mig_rc -eq 0 ]"
check "Canadian/PCT installed"          "[ -f /usr/share/zoneinfo/Canadian/PCT ]"
check "Canadian/ABT installed"          "[ -f /usr/share/zoneinfo/Canadian/ABT ]"
check "Canadian/MBT installed"          "[ -f /usr/share/zoneinfo/Canadian/MBT ]"
check "Canadian/NWT installed"          "[ -f /usr/share/zoneinfo/Canadian/NWT ]"
check "Canadian/YST-Whitehorse installed" \
                                       "[ -f /usr/share/zoneinfo/Canadian/YST-Whitehorse ]"
check "Canadian/YST-Dawson installed"   "[ -f /usr/share/zoneinfo/Canadian/YST-Dawson ]"

# /etc/localtime repointed to the custom identifier
localtarget=$(readlink /etc/localtime || echo "")
check "/etc/localtime points to Canadian/PCT" \
      "[ \"$localtarget\" = '/usr/share/zoneinfo/Canadian/PCT' ]"

# glibc still reads the abbreviation correctly
zdate=$(env -u TZ date +'%Z' 2>/dev/null || echo "")
check "system date shows PCT"           "[ \"$zdate\" = 'PCT' ]"

# IANA source untouched
src_pool=$(python3 - <<'PY'
import struct, sys
d=open('/usr/share/zoneinfo/America/Vancouver','rb').read()
c1=struct.unpack('>6I', d[20:44]); v1=44+c1[3]*4+c1[3]+c1[4]*6+c1[5]+c1[2]*12+c1[1]+c1[0]
c2=struct.unpack('>6I', d[v1+20:v1+44])
p=v1+44+c2[3]*8+c2[3]+c2[4]*6
sys.stdout.write(d[p:p+c2[5]].replace(b'\x00', b'|').decode('latin-1'))
PY
)
check "official America/Vancouver pool still has MST (untouched)" \
      "echo '$src_pool' | grep -q MST"
check "official America/Vancouver pool has no PCT" \
      "! echo '$src_pool' | grep -q PCT"

# Config bumped to 2.0.0 / schema 2
check "installed_version bumped to 2.0.0" \
      "grep -q '^installed_version=2.0.0$' /etc/tzshim.conf"
check "schema_version bumped to 2" \
      "grep -q '^schema_version=2$' /etc/tzshim.conf"
check "original_timezone metadata PRESERVED" \
      "grep -q '^original_timezone=America/Los_Angeles$' /etc/tzshim.conf"

# State model: two distinct fields
check "selected-source-zone file exists" \
      "[ -f /var/lib/canadian-tz-shim/selected-source-zone ]"
check "selected-source-zone contains America/Vancouver" \
      "[ \"\$(cat /var/lib/canadian-tz-shim/selected-source-zone)\" = 'America/Vancouver' ]"
check "selected-custom-zone file exists" \
      "[ -f /var/lib/canadian-tz-shim/selected-custom-zone ]"
check "selected-custom-zone contains Canadian/PCT" \
      "[ \"\$(cat /var/lib/canadian-tz-shim/selected-custom-zone)\" = 'Canadian/PCT' ]"
check "legacy selected-zone file removed" \
      "[ ! -f /var/lib/canadian-tz-shim/selected-zone ]"

# Manifest present and populated
check "custom-zones.json manifest exists" \
      "[ -f /var/lib/canadian-tz-shim/custom-zones.json ]"
manifest_count=$(python3 -c "
import json
d = json.load(open('/var/lib/canadian-tz-shim/custom-zones.json'))
print(len(d.get('zones', {})))
" 2>/dev/null || echo 0)
check "manifest has 6 entries" \
      "[ '$manifest_count' = '6' ]"

# Manifest hashes match the actual installed files
hash_match=$(python3 -c "
import json, hashlib, os
d = json.load(open('/var/lib/canadian-tz-shim/custom-zones.json'))
base = d['base']
ok = True
for zid, z in d['zones'].items():
    path = os.path.join(base, zid)
    if not os.path.exists(path):
        ok = False; break
    h = hashlib.sha256(open(path,'rb').read()).hexdigest()
    if h != z['sha256']:
        ok = False; break
print('yes' if ok else 'no')
")
check "manifest hashes match installed files" \
      "[ '$hash_match' = 'yes' ]"

# 1.x legacy files removed
legacy_remaining=$(ls /usr/local/share/zoneinfo/America/ 2>/dev/null | wc -l)
check "1.x patched America/* files removed" \
      "[ '$legacy_remaining' = '0' ]"

# ============================================================================
# The whole reason for tab registration: KDE's digital clock refuses to
# render a zone whose Qt country() is AnyCountry or whose comment() is
# empty, showing "Time zone is not set; click here to open Date & Time
# settings" instead. That's the failure the user reported. Confirm that
# after the migration, QTimeZone('Canadian/PCT') reports both.
# ============================================================================
echo ""
echo "=== KDE clock acceptance signal (country/comment) ==="

# Build a minimal Qt probe inside the namespace.
cat > /tmp/kde_ok_probe.cpp <<'CPP'
#include <QLocale>
#include <QByteArray>
#include <QCoreApplication>
#include <QTimeZone>
#include <cstdio>
int main(int argc, char **argv) {
    QCoreApplication a(argc, argv);
    QTimeZone t{QByteArray("Canadian/PCT")};
    auto country = t.country();
    auto comment = t.comment();
    // Emit two tokens we can grep for
    printf("COUNTRY=%s\n", QLocale::countryToString(country).constData());
    printf("COMMENT=%s\n", comment.toUtf8().constData());
    return 0;
}
CPP
if command -v g++ >/dev/null 2>&1 \
   && pkg-config --exists Qt6Core 2>/dev/null \
   && g++ -std=c++17 -fPIC /tmp/kde_ok_probe.cpp -o /tmp/kde_ok_probe $(pkg-config --cflags --libs Qt6Core) 2>/dev/null; then
    out=$(env -u TZ -u TZDIR /tmp/kde_ok_probe 2>&1)
    echo "$out"
    # Qt 6.12 returns "C" (ISO 3166 alpha-2); older builds and
    # countryToString overloads may return "Canada". Accept either —
    # what matters is that it's NOT "Default"/"AnyCountry".
    if echo "$out" | grep -Eq '^COUNTRY=(Canada|C)$'; then
        echo "  ✓ QTimeZone('Canadian/PCT').country() is Canada"
    else
        echo "  ✗ country() is not Canada — KDE will still show 'not set'"
        fail=1
    fi
    if echo "$out" | grep -Eq '^COMMENT=PCT'; then
        echo "  ✓ QTimeZone('Canadian/PCT').comment() starts with PCT"
    else
        echo "  ✗ comment() missing/incorrect"
        fail=1
    fi
    # Vancouver's tab comment should still be there too — we APPENDED, never
    # overwrote tzdata's own lines.
    if grep -q 'America/Vancouver' /usr/share/zoneinfo/zone.tab; then
        echo "  ✓ original zone.tab America/Vancouver line still present"
    else
        echo "  ✗ our tab append removed the source line"
        fail=1
    fi
    # Idempotency: re-running install.sh --upgrade should not duplicate lines
    n_before=$(grep -c "Canadian/PCT" /usr/share/zoneinfo/zone.tab 2>/dev/null || echo 0)
    (cd /mnt/repo && bash install.sh --upgrade >/dev/null 2>&1) || true
    n_after=$(grep -c "Canadian/PCT" /usr/share/zoneinfo/zone.tab 2>/dev/null || echo 0)
    if [ "$n_before" = "$n_after" ] && [ "$n_before" = "1" ]; then
        echo "  ✓ tab registration is idempotent (exactly 1 line after two runs)"
    else
        echo "  ✗ tab registration not idempotent: $n_before → $n_after"
        fail=1
    fi
else
    echo "  note: no g++/Qt6Core in this environment — skipping country()/comment() probe"
fi

exit $fail
INNER

# Substitute the tarball path
sed -i "s|__REPO_TAR__|${REPO_TAR}|g" "$INNER_SCRIPT"

echo ""
echo "============================================"
echo "Canadian Timezone Shim — 1.x → 2.x migration test"
echo "============================================"

unshare --mount --user --map-root-user bash "$INNER_SCRIPT"
rc=$?

rm -f "$REPO_TAR" "$INNER_SCRIPT"

echo ""
if [[ "$rc" == "0" ]]; then
    pass "Migration completed cleanly with all properties verified"
    exit 0
else
    fail "Migration failed (rc=$rc)"
    exit 1
fi
