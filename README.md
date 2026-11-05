# Canadian Timezone Shim

A Linux shim that makes your system's local time display match the
official Canadian provincial and territorial time designations, without
modifying any tzdata package files.

Current version: **2.0.0**. See
[`DESKTOP_COMPANION_IMPLEMENTATION.md`](DESKTOP_COMPANION_IMPLEMENTATION.md)
for the architecture and verification record.

## Background

Several Canadian provinces and territories have adopted permanent
daylight saving time with official names that differ from IANA's
conventions:

| Region                     | Official   | IANA uses | Offset   | Effective    |
|----------------------------|------------|-----------|----------|--------------|
| British Columbia           | **PCT**    | MST       | −07:00   | Nov 1 2026   |
| Alberta                    | **ABT**    | CST       | −06:00   | Nov 1 2026   |
| Yukon                      | **YST**    | MST       | −07:00   | Nov 1 2020   |
| Manitoba                   | **MBT**    | EST       | −05:00   | Nov 1 2026   |
| Northwest Territories      | **NWT**    | CST       | −06:00   | Nov 1 2026   |

The shim installs custom TZif files under `/usr/share/zoneinfo/Canadian/`
and points `/etc/localtime` at the selected one, so `date`, `TZ`,
Python's `zoneinfo`, and desktop clocks all show the correct Canadian
abbreviation while every pre-transition date still shows `PST`, `PDT`,
`MST`, `CST`, or `EST` exactly as it did before.

## What this is — and is not

- **Non-destructive.** Official IANA TZif files under
  `/usr/share/zoneinfo/America/*` are never modified.
- **Custom namespace.** The identifiers are `Canadian/PCT`,
  `Canadian/ABT`, `Canadian/MBT`, `Canadian/NWT`,
  `Canadian/YST-Whitehorse`, `Canadian/YST-Dawson`. These are **custom
  project identifiers, not IANA-published names.** The shim registers
  them narrowly in `zone.tab` / `zone1970.tab` so the system's timezone
  stack treats them like any other zone; uninstall removes exactly the
  registration lines the shim added and touches nothing else.
- **Reversible.** Everything the shim creates or changes is recorded in
  an ownership manifest at `/var/lib/canadian-tz-shim/custom-zones.json`
  (or `~/.local/state/canadian-tz-shim/custom-zones.json` in user
  scope) and undone cleanly by `uninstall.sh`.
- **Idempotent.** Safe to re-run.

## Installation

### System-wide (recommended)

```bash
sudo ./install.sh
```

Detects your current zone from `/etc/localtime`, generates every
`Canadian/*` custom TZif file from its IANA source, validates each
against fixed historical and future dates, installs them atomically
under `/usr/share/zoneinfo/Canadian/`, registers them in `zone.tab`
and `zone1970.tab`, repoints `/etc/localtime`, and installs a systemd
path unit that rebuilds the custom zones whenever tzdata updates.

### User-level only

```bash
./install.sh
```

Installs the same custom zones under `~/.tzinfo/Canadian/`. Use them
by setting `TZ` to the absolute path in your shell profile:

```bash
export TZ=$HOME/.tzinfo/Canadian/PCT
```

**Caveat for desktop clocks:** Qt (which underlies KDE, GNOME, and the
other desktop clocks tested here) searches `/usr/share/zoneinfo/` and
does not discover `~/.tzinfo/`. For a desktop clock to show the
Canadian abbreviation, install system-wide. Command-line tools
(`date`, `TZ=…`, Python's `zoneinfo`) honour the user-scope install
correctly.

### After install — one-time plasmashell restart (KDE only)

Qt parses `zone.tab` once at process start, so the digital clock
won't recognise the custom zone until plasmashell reloads. Restart it
once after install or upgrade:

```bash
systemctl --user restart plasma-plasmashell.service
```

That's the only action needed on a normal KDE setup — the clock uses
`Local` mode, which now resolves through the system tz. No Plasma
configuration file changes are required. Log-out/log-in also works
if you prefer.

## Verifying

```bash
# Local clock
date +"%Z %z"                                 # → PCT -0700

# Custom identifier resolves at fixed dates
TZ=Canadian/PCT date -d "2026-12-15" +"%Z %z" # → PCT -0700
TZ=Canadian/PCT date -d "2025-01-15" +"%Z %z" # → PST -0800
TZ=Canadian/PCT date -d "2025-07-15" +"%Z %z" # → PDT -0700

# Official IANA source is still untouched
TZ=America/Vancouver date -d "2026-12-15" +"%Z %z"  # → MST -0700

# tzdata watcher is armed (system scope)
systemctl status canadian-tz-shim.path
```

## Uninstalling

```bash
sudo ./uninstall.sh           # system-wide
./uninstall.sh                # user scope
```

The uninstaller:

1. Stops and removes the systemd path unit.
2. Restores `/etc/localtime` to the originally recorded zone using the
   metadata preserved in `/etc/tzshim.conf`.
3. Removes exactly the tab-file lines recorded in the manifest.
4. Removes each `Canadian/*` TZif file **only** when its hash still
   matches the recorded ownership — refuses to delete files that were
   hand-modified.
5. Refuses to remove files the shim did not create, even if they share
   the `Canadian/` path.
6. Prunes the empty `Canadian/` namespace directory and cleans up any
   1.x leftover patched files it detects under
   `/usr/local/share/zoneinfo/America/`.
7. Removes the state directory and config file.

If restoration of `/etc/localtime` fails, the uninstaller keeps every
custom zone in place rather than leave the system with a dangling
symlink. `--force` is available but only if you've already restored
`/etc/localtime` manually.

## Upgrading

Re-run `sudo ./install.sh` — the installer is idempotent. If you're
migrating from a 1.x release (patched `America/*` files under
`/usr/local/share/zoneinfo/`), use:

```bash
sudo ./install.sh --upgrade
```

The 1.x → 2.x upgrade is a formal transactional migration with
automatic rollback if any step fails. It installs the `Canadian/*`
custom zones, repoints `/etc/localtime`, retires the 1.x layout, and
preserves your original-timezone restoration metadata throughout.
See [`UPGRADE_SYSTEM.md`](UPGRADE_SYSTEM.md) for the operation list
and rollback semantics.

## Desktop clocks that store an explicit zone

Most desktops read `/etc/localtime` and need no configuration change.
The narrow exception is a clock widget where the user manually picked
an IANA identifier (KDE's digital clock "Selected time zone" mode,
for example). For those cases the companion utility migrates just the
one stored identifier:

```bash
./desktop-patch/desktop-patch.sh --desktop kde
./desktop-patch/desktop-patch.sh --desktop gnome --dry-run
./desktop-patch/desktop-patch.sh --restore
./desktop-patch/desktop-patch.sh --status
```

If the desktop follows `/etc/localtime`, the companion says so and
performs no write. See
[`desktop-patch/README.md`](desktop-patch/README.md).

## Supported desktops

| Desktop     | Verified how                          | Result |
|-------------|---------------------------------------|--------|
| KDE Plasma  | **Live verified** on the dev machine  | Digital clock renders `PCT` after plasmashell restart; explicit stored ids can be migrated by the companion |
| GNOME       | Integration verified (Docker)         | The desktop's GSettings stack exposes no per-user timezone key on Debian trixie; follows `/etc/localtime`; companion correctly writes nothing |
| Cinnamon    | Integration verified (Docker)         | Same outcome as GNOME |
| MATE        | Integration verified (Docker)         | Same outcome as GNOME |
| Budgie      | Integration verified (Docker)         | Same outcome as GNOME |
| XFCE        | Integration verified (Docker)         | Companion discovers the real clock plugin's `Timezone` Xfconf property; apply + restore round-trip verified against the live Xfconf D-Bus service |
| LXQt        | Fixture verified (Docker, shipped default `panel.conf`) | Companion correctly rewrites the `timezone=` key inside the real LXQt widget section; unrelated sections preserved. No running panel was exercised. |

## Important limitations

- **KDE requires a one-time `plasmashell` restart** after install or
  upgrade for the digital clock to see the new `zone.tab` entry.
  Configuration files themselves need no editing.
- **User-scope install does not change desktop clocks.** Qt searches
  `/usr/share/zoneinfo/` only.
- **`American/Yellowknife` upstream has no `zone.tab` entry.** The
  shim installs `Canadian/NWT` as a working TZif file (glibc, Python,
  `date` all resolve it correctly) but does not register a country
  code or map coordinates for it — because there is no source entry
  to copy. This is an upstream tzdata property, not a bug in this
  project.
- **`Canadian/*` identifiers are custom**, not IANA-published.
  Software outside the tzfile-searching ecosystem (older libraries
  that ship their own compiled-in zone list, ICU consumers that
  bypass the system tzdata, etc.) may not know about them.

## Testing

```bash
./test.sh                             # install lifecycle + historical correctness
./test-upgrade.sh                     # version-aware upgrade machinery
./test-regressions.sh                 # past-defect guards + patcher audit
./test-uninstall-edge-cases.sh        # uninstall scenarios
./test-custom-zones.sh                # custom-zone library + tab registration
./test-migration.sh                   # 1.x → 2.x transaction inside a mount namespace
./desktop-patch/test-desktop-patch.sh # companion utility
./test-isolation.sh                   # asserts all of the above never touch the real $HOME
./live-kde-verify.sh                  # end-to-end namespace verification with a Qt probe
```

The opt-in Docker matrix for the non-KDE desktops lives in
`desktop-patch/docker/` and is documented in
[`desktop-patch/docker/README.md`](desktop-patch/docker/README.md).
The Docker harness is part of the source repository but is excluded
from the release archive by `package-release.sh`.

## References

- [BC Government: B.C.'s new time zone (Pacific time)](https://www.gov.bc.ca/gov/content/governments/celebrating-british-columbia/daylight-saving-time)
- [Alberta Government: Alberta's new time system (ABT)](https://www.alberta.ca/albertas-new-time-system-abt)
- [Yukon Government: Learn about Yukon Standard Time](https://yukon.ca/en/your-government/about-yukon/learn-about-yukon-standard-time)
- [Manitoba Government: No More Falling back](https://www.gov.mb.ca/timechange/)
- [NWT Government: Northwest Territories Time](https://gnwt.ca/sport-recreation-and-tourism/living-nwt/northwest-territories-time)
- [IANA Time Zone Database](https://www.iana.org/time-zones)
- [RFC 8536: The TZif Format](https://datatracker.ietf.org/doc/html/rfc8536)

## License

MIT License — see LICENSE file for details.

## Disclaimer

This is an unofficial community tool. It is not endorsed by IANA, any
provincial or territorial government, or any timezone authority. It
exists to give users a choice in how they display timezone information.
