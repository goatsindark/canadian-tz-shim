# Implementation Report — 2.0.0

Single source of truth for the architecture, verification evidence, and
known limitations of the Canadian Timezone Shim as released at version
2.0.0. User-facing documentation lives in `README.md`,
`desktop-patch/README.md`, `desktop-patch/docker/README.md`, and
`UPGRADE_SYSTEM.md`. This report is the technical companion for
maintainers and reviewers.

## What was built

A two-part system:

- **Core shim** (`install.sh`, `uninstall.sh`, `lib/reapply.sh`,
  `lib/custom_zones.sh`, `lib/patch_tzif.py`, `lib/upgrade.sh`) —
  generates project-owned custom TZif identifiers under
  `/usr/share/zoneinfo/Canadian/` (or `~/.tzinfo/Canadian/` in
  user scope), registers each custom identifier in
  `/usr/share/zoneinfo/zone.tab` and `zone1970.tab`, repoints
  `/etc/localtime`, records ownership in a system manifest, and
  rebuilds everything after a tzdata update.

- **Companion utility** (`desktop-patch/`) — migrates a single
  desktop-side stored timezone identifier from the IANA source to the
  matching custom `Canadian/*` identifier, only when the desktop
  actually stores one. If the desktop follows `/etc/localtime`, the
  companion reports that and performs no write.

The core owns TZif generation, validation, atomic install, tzdata
reapply, system-scope `/etc/localtime`, uninstall, and the migration
transaction. The companion owns only desktop settings, never TZif
content.

## Why the `Canadian/*` namespace exists

The 1.x shim patched the abbreviation inside a copy of each IANA file
stored under `/usr/local/share/zoneinfo/America/<City>`, and pointed
`/etc/localtime` at that copy. That approach had a bug the 2.x design
exists to fix: **Qt's timezone backend reads the system tzfile from
`/usr/share/zoneinfo/`, not from `/usr/local/share/zoneinfo/`.**

Verified empirically with a C++ probe against both Qt 5.15.19 and
Qt 6.12.0 (the KDE Plasma 5 and KDE Plasma 6 stacks):

```
QTimeZone("America/Vancouver") on a 1.x system:
  id       = 'America/Vancouver'
  abbr     = 'MST'      ← from /usr/share/zoneinfo (unpatched)
  TZDIR=/usr/local/share/zoneinfo ignored
  TZ=<absolute path> yields an empty/invalid QTimeZone
```

Because the 1.x patch lived at a path Qt never opens, the shim's
patch was invisible to KDE's digital clock. `date` and every other
glibc consumer saw `PCT`; the clock still showed `MST`.

The 2.x design does not modify any official IANA file. Instead it
copies the source, patches the copy, and installs it at a **new
identifier in a directory Qt already scans**:

```
/usr/share/zoneinfo/America/Vancouver   (read-only source, never written)
    ↓ copy to staging file inside /usr/share/zoneinfo/Canadian/
    ↓ targeted abbreviation patch (lib/patch_tzif.py)
    ↓ structural + era validation
    ↓ same-filesystem rename
/usr/share/zoneinfo/Canadian/PCT        ← Qt scans this path automatically
    ↓
/etc/localtime → /usr/share/zoneinfo/Canadian/PCT
```

The `Canadian/` prefix is a **custom namespace owned by this project**.
It is not published by IANA, and no IANA identifier begins with it,
so there is no future collision risk. Every file under `Canadian/`
is one the shim created.

`Canada/Pacific` (which does exist upstream) is deliberately **not**
used as the namespace. It's IANA's, hardlinked to
`America/Vancouver`, and its abbreviation is what the whole exercise
is trying to change.

## Why table registration in `zone.tab` / `zone1970.tab` is required

Adding the TZif file at `/usr/share/zoneinfo/Canadian/PCT` makes
`QTimeZone("Canadian/PCT").isValid()` return `true` and the
identifier show up in `availableTimeZoneIds()`. But KDE's digital
clock went further and refused to display it, showing
*"Time zone is not set; click here to open Date & Time settings and
set one"*.

Root cause: Qt's `QTimeZone::country()` and `QTimeZone::comment()` —
which Plasma's `libdigitalclockplugin.so` uses to populate its
`localTimeZoneCity` QML binding — are parsed from
`/usr/share/zoneinfo/zone.tab` and `zone1970.tab`, not from the
TZif file body. Without a matching line in the tab, both signals come
back empty, the QML binding treats it as unset, and the applet shows
the "not set" placeholder.

Direct probe on the pre-fix state:

```
Zone: Canadian/PCT  valid=1
  country():  enum=0  (ISO='Default')
  comment():  ''
```

Which matches the state of an identifier the tab doesn't list, e.g.
`Etc/UTC` or a hardlink alias like `Canada/Pacific` (whose real file
content is fine, but which also isn't in the tab).

**Fix:** the installer appends one line per custom identifier to each
of `zone.tab` and `zone1970.tab`, derived from the source's existing
line. Coordinates and country code are copied verbatim; only the Tz
field (`Canada/Pacific` → `Canadian/PCT`) and the leading
abbreviation token in the comment (`MST - BC …` → `PCT - BC …`)
change. Post-fix:

```
Zone: Canadian/PCT  valid=1
  country():  enum=41  (ISO='Canada')
  comment():  'PCT - BC (most areas)'
```

Registration is **narrow, idempotent, and reversible**:

- Every added line is recorded verbatim in `custom-zones.json` under
  the custom id's `tab_lines` map.
- Re-running install replaces the line if it exists but differs,
  appends if it doesn't, and does nothing if the recorded line is
  already present.
- Uninstall removes only the exact recorded line, via a literal
  string match (`grep -Fxv`). It refuses to remove anything it
  didn't add and doesn't touch entries that differ from what it
  recorded (indicating a hand-edit or a package upgrade that
  replaced the file).
- The original tzdata-provided lines (`America/Vancouver`,
  `America/Edmonton`, etc.) are never modified or removed.

**Restart requirement.** Qt caches the tab file at process startup
and does not listen for edits. After install or upgrade, KDE needs a
one-time plasmashell restart so the digital clock re-parses
`zone.tab`:

```bash
systemctl --user restart plasma-plasmashell.service
```

No logout is required; no Plasma configuration file needs editing.

**Upstream tzdata limit.** `America/Yellowknife` has no canonical
entry in either tab file — upstream tzdata only lists `America/Denver`
and similar, with Yellowknife reachable via the backward file. That
means `Canadian/NWT` gets a valid installed TZif file (glibc, Python,
`date`, and `TZ=Canadian/NWT date` all resolve it to `NWT`), but no
`zone.tab` entry — because there's no source line to derive one
from. The installer emits a specific note and continues; the
install does not fail. KDE will show the time correctly (via the
`Local` mode + `/etc/localtime` symlink) but has no country or
coordinates to display for that particular identifier. This is an
upstream data property, not a bug in this project.

## What the installer modifies vs. leaves untouched

### Modified by the installer (all reversible, all recorded)

| Path                                            | Change                                       | Reversible by |
|-------------------------------------------------|----------------------------------------------|---------------|
| `/usr/share/zoneinfo/Canadian/*` (new directory + files) | Created. Each file is generated from a source IANA TZif. | `uninstall.sh` deletes exactly the files recorded in `custom-zones.json`. |
| `/usr/share/zoneinfo/zone.tab`                  | One narrow line appended per custom identifier (from the source's line). | `uninstall.sh` removes exactly the recorded lines, literal-match only. |
| `/usr/share/zoneinfo/zone1970.tab`              | Same as above.                                | Same. |
| `/etc/localtime`                                | Repointed at the selected `Canadian/*` file.   | Restored to the recorded `original_timezone` on uninstall. |
| `/etc/tzshim.conf`                              | Created / updated with restoration metadata and `installed_version` / `schema_version`. | Removed on uninstall. |
| `/var/lib/canadian-tz-shim/*`                   | State files (`selected-source-zone`, `selected-custom-zone`, `installed-scope`, `installed-version`, `custom-zones.json`). | Removed on uninstall. |
| `/usr/local/libexec/canadian-tz-shim/*`         | Runtime copies of `patch_tzif.py`, `custom_zones.sh`, `reapply.sh`. | Removed on uninstall. |
| `/usr/local/share/canadian-tz-shim/zones.conf`  | Copy of the config file used by the systemd unit. | Removed on uninstall. |
| `/etc/systemd/system/canadian-tz-shim.{service,path}` | Units that re-run the patch when tzdata changes. | Disabled + removed on uninstall. |

### Never modified

- **Every official IANA TZif file** under `/usr/share/zoneinfo/America/*`,
  `/usr/share/zoneinfo/Etc/*`, etc. The installer only ever **reads**
  them as sources.
- **Every tzdata-provided `zone.tab` / `zone1970.tab` line.** The
  installer appends and removes only its own additions.
- **Any `Canadian/*` file the shim didn't install.** Ownership is
  proven by a sha256 match in `custom-zones.json`, not by the file
  existing. If someone else drops a file at
  `/usr/share/zoneinfo/Canadian/Weird`, the installer refuses to
  overwrite it and reports the collision.
- **`/usr/share/zoneinfo/posix/`, `right/`, `zone1970.tab`'s
  pre-existing content, `zone.tab`'s pre-existing content,
  `leapseconds`, `iso3166.tab`, and every other tzdata metadata
  file** beyond the two tab files explicitly named above.
- **ICU data files, Qt data files, or any other library's compiled-in
  timezone database.** None of them are touched; the shim operates
  on `/usr/share/zoneinfo/` only.

## Desktop verification levels

Each adapter was verified at the level its evidence honestly supports.
The definitions are:

- **Live verified** — real desktop session, visual confirmation.
- **Integration verified** — real distro-packaged schemas/services,
  driven through the actual configuration API in an isolated
  container.
- **Fixture verified** — only against realistic configuration files
  representing what the desktop writes; the real service wasn't run.
- **Unsupported** — the responsible setting couldn't be identified
  confidently.

| Desktop  | Level                    | Evidence |
|----------|--------------------------|----------|
| **KDE Plasma** | **Live verified**   | Real KDE Plasma 6.8.2 session on the dev machine. Visual confirmation: after `systemctl --user restart plasma-plasmashell.service` the digital clock renders the local time with the Canadian abbreviation; the world-clock map highlights British Columbia; the "Time zone is not set" message is gone. Independently verified by `live-kde-verify.sh` (17 fixed-date Qt 5 / Qt 6 assertions inside a private mount + user namespace, `country()=Canada` + `comment()` correct after tab registration) and by `test-migration.sh` (30 assertions, including a live Qt probe). |
| **GNOME**     | Integration verified | Real `gsettings-desktop-schemas` on Debian trixie inside Docker. Verified directly: `org.gnome.desktop.datetime` exposes only `automatic-timezone` on this distro — no per-user timezone string key. Therefore GNOME's clock follows `/etc/localtime` and the companion correctly writes nothing. 5/0 checks pass. |
| **Cinnamon**  | Integration verified | Real Cinnamon schemas on Debian trixie. No `org.cinnamon.desktop.datetime` schema in any Debian Cinnamon package; no per-user tz key at all. Companion correctly reports "no key, follows /etc/localtime". 4/0 checks pass. |
| **MATE**      | Integration verified | Real `mate-settings-daemon` + `mate-panel` schemas on Debian trixie. No explicit per-user timezone key present in the packaged MATE schemas here. 4/0 checks pass. |
| **Budgie**    | Integration verified | Uses `gsettings-desktop-schemas` transitively; same outcome as GNOME. 5/0 checks pass. |
| **XFCE**      | Integration verified | Real Xfconf D-Bus service running in a private session inside the container. `xfconf-query` round-trips `Canadian/PCT` as a string, the clock plugin's `Timezone` property is discovered at `/plugins/plugin-<N>/Timezone` via the correct Xfconf schema, the adapter's dry-run / apply / verify / restore cycle all pass against the live service. 10/0 checks. |
| **LXQt**      | **Fixture verified** (against the real shipped default) | Tested inside a container with the actual `lxqt-panel` package installed and against the real `/usr/share/lxqt/panel.conf` layout: one section per widget with a `type=` field inside. The adapter discovers widget sections correctly, rewrites only the `timezone=` key inside `[clock]` or `[worldclock]`, preserves every other widget section and unrelated key, and restores on demand. No running panel was started; the actual rendering is not covered. 23/0 checks. |

**What "renders_expected_abbreviation = yes" means on the non-KDE
rows.** For XFCE and LXQt it means the underlying tzfile lookup chain
(glibc `date` with `TZ=<custom id>`, Qt 6 `QTimeZone` for XFCE's
panel context) resolves the custom identifier to the expected
abbreviation at the fixed test instants. For GNOME, Cinnamon, MATE,
and Budgie, it means `/etc/localtime` resolves through to the same
abbreviation via the system path. It does not mean a widget was
visually observed rendering the abbreviation in a live graphical
session — only the KDE row has that stronger claim.

## Docker matrix

`desktop-patch/docker/` is an opt-in container test harness for the
six non-KDE desktops. It is **present in the source repository** and
**excluded from the end-user release archive** by `package-release.sh`
(see `EXCLUDE_PREFIXES`). Running it requires a working Docker daemon
and network access to `deb.debian.org`.

Each container is built on `debian:trixie-slim` and installs only the
specific configuration backend its desktop's clock widget actually
consults — the real `gsettings-desktop-schemas`,
`cinnamon-desktop-data`, `mate-panel` + `mate-settings-daemon`,
`xfce4-panel` + `xfconf` + `xfce4-settings`, or `lxqt-panel`. No full
desktop environment is installed. The core shim's `install.sh` runs
during the image build so the `Canadian/*` files and their tab
entries exist inside the container. At test time, `run-tests.sh`
launches the container with `--rm --network=none`, the entrypoint
drops to an unprivileged `dtp` user via `setpriv`, and any GSettings
or Xfconf test runs inside a private `dbus-run-session` so no host
bus is ever visible.

The container does **not** use `--privileged`, `--net=host`, or any
host-directory bind mount. It does **not** use `--cap-drop=ALL`,
because the entrypoint requires `SETGID`/`CHOWN` to create the
unprivileged user and set up its HOME — Docker's default capability
set is already correct for the isolation we need.

Final result of a full run against the shipped Dockerfiles:

```
GNOME     PASS   5/0  integration verified
Cinnamon  PASS   4/0  integration verified
MATE      PASS   4/0  integration verified
Budgie    PASS   5/0  integration verified
XFCE      PASS  10/0  integration verified (real Xfconf service)
LXQt      PASS  23/0  fixture verified against shipped panel.conf default
```

## What was tested

Full local suite (all runnable unprivileged, all in the release archive):

| Suite | Result |
|-------|--------|
| `test.sh` | 44 / 44 |
| `test-upgrade.sh` | 13 / 13 |
| `test-regressions.sh` | 23 / 23 (includes R13 patcher audit against all 6 sources, R14 multi-match refusal, R15 substring preservation) |
| `test-uninstall-edge-cases.sh` | passing |
| `test-custom-zones.sh` | 51 / 51 |
| `test-migration.sh` | 30 assertions (private namespace, real 1.x fixture, real Qt 6 probe) |
| `desktop-patch/test-desktop-patch.sh` | 53 / 53 |
| `test-isolation.sh` | 7 / 7 |

Namespace / container verification:

| Verification | Result |
|--------------|--------|
| `live-kde-verify.sh` (host + private mount namespace) | 0 failures, 17 fixed-date Qt assertions |
| Docker desktop matrix | 6 / 6 PASS |

Every local suite is wrapped by `test-isolation.sh`, which snapshots
the developer's real `$HOME`, `/etc/localtime`, and `/etc/tzshim.conf`
before and after each suite and fails if any of them changed.

## Release packaging

`package-release.sh` builds the release archive with these rules:

**Included in the archive**

- The core: `install.sh`, `uninstall.sh`, `zones.conf`, `migrations.json`,
  `lib/custom_zones.sh`, `lib/patch_tzif.py`, `lib/reapply.sh`,
  `lib/upgrade.sh`, `lib/canadian-tz-shim.service`,
  `lib/canadian-tz-shim.path`.
- User-facing docs: `README.md`, `UPGRADE_SYSTEM.md`,
  `DESKTOP_COMPANION_IMPLEMENTATION.md`, `LICENSE`.
- Companion utility: `desktop-patch/desktop-patch.sh`, its
  `shared/`, `backends/`, and `adapters/` subdirectories, its
  `README.md`, and `desktop-patch/test-desktop-patch.sh`.
- Every shipped test suite (`test.sh`, `test-upgrade.sh`,
  `test-uninstall-edge-cases.sh`, `test-regressions.sh`,
  `test-custom-zones.sh`, `test-migration.sh`, `test-isolation.sh`).
- `tools/patcher_audit.py` (invoked by `test-regressions.sh` R13).

**Excluded from the archive** (source repository only)

- `desktop-patch/docker/` — the container matrix is a development
  harness, requires Docker and outbound network to `deb.debian.org`,
  and its images aren't useful to end users without that setup.
- `live-kde-verify.sh` and `tools/tz_probe.cpp` — dev-only
  namespace verification that requires `unshare` and Qt 6 dev
  headers on the local machine.
- `.git/`, `bin/`, `docs/`, `dist/`, `__pycache__/`, and scratch
  artifacts.

The distinction is enforced by `EXCLUDE_PREFIXES` in
`package-release.sh`, and the packaging script asserts post-build
that no excluded path leaked into the archive.

## Known limitations

- **KDE needs a one-time `plasmashell` restart** after install or
  upgrade. Qt parses `zone.tab` at process startup and doesn't
  listen for external edits. Documented in `README.md` and
  `UPGRADE_SYSTEM.md`.
- **`American/Yellowknife` has no `zone.tab` entry upstream.** The
  shim installs `Canadian/NWT` correctly but skips its tab
  registration; the note appears at install time. The system-wide
  clock (via `/etc/localtime`) and the digital clock in `Local`
  mode still work; only the map marker and country label are
  missing.
- **User-scope install doesn't affect desktop clocks.** Qt scans
  `/usr/share/zoneinfo/` only.
- **LXQt verification is fixture-level**, not integration-verified:
  the container tests the file format against the real shipped
  default `panel.conf`, but doesn't run `lxqt-panel` visually.
- **`desktop-patch/` currently ships only for the seven desktops
  above.** Deepin, Pantheon, i3, sway, Hyprland, and other compositors
  aren't covered because their clock storage mechanisms weren't
  verified in this release.

## Files added since 1.0.0

- `lib/custom_zones.sh` — the custom-zone pipeline (parse, validate,
  generate, atomic install, tab register/unregister, manifest I/O).
- `test-custom-zones.sh` — 51 isolated checks against the pipeline.
- `test-migration.sh` — 30-assertion transactional 1.x → 2.x test
  inside a private mount + user namespace.
- `live-kde-verify.sh` — namespace + Qt 6 end-to-end verification.
- `tools/patcher_audit.py` — regression tool that audits
  `lib/patch_tzif.py` against every era boundary in every real
  Canadian source TZif; runs as R13 in `test-regressions.sh`.
- `tools/tz_probe.cpp` — Qt 5/6 fixed-date probe compiled by
  `live-kde-verify.sh` on demand.
- `desktop-patch/desktop-patch.sh`, `desktop-patch/shared/*`,
  `desktop-patch/backends/*`, `desktop-patch/adapters/*` — the
  companion utility.
- `desktop-patch/docker/` — container matrix for the six non-KDE
  desktops (source-repo only).
- `desktop-patch/README.md`, `desktop-patch/docker/README.md`,
  `DESKTOP_COMPANION_IMPLEMENTATION.md` (this file).

## Files substantially modified since 1.0.0

- `install.sh` — full pipeline rewrite around `custom_zones.sh`; new
  1.x → 2.x `--upgrade` branch that goes through the migration
  transaction rather than falling through to a plain install.
- `uninstall.sh` — manifest-driven removal; explicit tab-line
  removal; refusal to delete externally modified files; 1.x leftover
  cleanup with abbreviation-pool safety check.
- `lib/patch_tzif.py` — hardened to NUL-bounded pool matching,
  multi-match refusal, substring preservation; era-verified against
  the six real sources in R13.
- `lib/reapply.sh` — now driven by `custom_zones_rebuild_all`; also
  refreshes tab registrations after tzdata overwrites them.
- `lib/upgrade.sh` — new migration operations
  (`generate_custom_zones`, `relink_localtime_to_custom`,
  `update_state_model`, `remove_legacy_zoneinfo`); BFS upgrade path
  resolver; extended backup/restore to cover both the legacy and the
  new layouts.
- `migrations.json` — current_release bumped to `2.0.0`,
  schema_version to `2`; new 1.0.0 → 2.0.0 transactional migration
  entry with the operation list above.
- `zones.conf` — 6-field format with the `CUSTOM_ID` column
  explicitly documenting the `Canadian/*` namespace as custom.
- `test.sh`, `test-regressions.sh`, `test-isolation.sh`,
  `package-release.sh` — updated for the new layout and shipped
  test list.
- `README.md`, `UPGRADE_SYSTEM.md` — rewritten for the 2.x
  architecture.

## Historical superseded findings

For reference during review, the following claims appeared in earlier
design iterations of this project and are **not** part of the final
2.0.0 release:

- **"The shim never modifies `zone.tab` or `zone1970.tab`."**
  Superseded by the empirical discovery (see *Why table registration
  is required* above) that KDE treats the digital clock as unset
  without a matching tab entry. The 2.0.0 shim now appends
  narrow, idempotent, reversible lines and documents the exact
  ownership / rollback rules.
- **"Upgrading from 1.x just falls through to a fresh install."**
  Superseded by the transactional migration implemented in this
  release.
- **"An LD_PRELOAD library is required to make KDE read the patched
  TZif."** Explored early and abandoned: the custom-identifier
  approach makes any interception unnecessary. No shim library is
  shipped.
- **"The 1.x patched `/usr/local/share/zoneinfo/America/*` files
  remain on disk indefinitely after upgrade."** Superseded by the
  migration's `remove_legacy_zoneinfo` step, which deletes them (as
  verified by their patched abbreviation pool) as part of the
  transaction and restores them if the transaction rolls back.
