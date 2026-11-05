# Upgrade System

How `install.sh --upgrade` moves the system from one release of the
Canadian Timezone Shim to another.

## Overview

The upgrade path is defined declaratively in `migrations.json` and
executed by `lib/upgrade.sh`. Each migration is a transaction: a
backup is captured before any operation runs, every operation is
executed in order, and a post-upgrade validation gate runs on success.
If any step fails, the whole transaction is rolled back from the
backup and the system is returned to its pre-upgrade state.

Supported in 2.0.0:

- **0.8.0 → 0.9.0 → 1.0.0 → 2.0.0** chained migrations, resolved by
  BFS over the migration graph in `migrations.json`.
- Legacy detection of installations that never wrote
  `installed_version` (pre-0.8.0 releases). Those are treated as the
  earliest supported version.

## Usage

```bash
# Preview
sudo ./install.sh --upgrade --dry-run

# Perform
sudo ./install.sh --upgrade
```

`--dry-run` prints the operation list that would execute and changes
nothing. It never acquires the lock or writes backups.

## Upgrade states

`install.sh --upgrade` classifies the current installation into one
of:

| State             | Meaning                                                       | Action |
|-------------------|---------------------------------------------------------------|--------|
| `not_installed`   | No config file, no managed files                              | error, exit |
| `current`         | Installed version equals `CURRENT_VERSION`                    | exit 0 |
| `upgrade_available` | Installed version is older and a path exists                | run transactional migration |
| `repair_required` | Installed version matches but health checks fail              | run the same operations as an upgrade — the transaction rebuilds managed files |
| `unsupported`     | Installed version has no path to the current release          | error, exit |
| `ambiguous`       | Version present but no schema version recorded                | error, exit |

Health checks in the 2.0.0 layout cover:

- Every `Canadian/*` custom TZif file exists under the target base and
  passes structural validation.
- `original_timezone` or `original_timezone_path` metadata is present
  for system-scope installs (required for safe uninstall).
- The `custom-zones.json` manifest exists and its recorded hashes
  match the installed files.

## Migration operations

Each operation is one case in `execute_migration_operation()` inside
`lib/upgrade.sh`. The 1.0.0 → 2.0.0 entry in `migrations.json`
declares them in order:

1. **`backup_metadata`** — snapshot `/etc/tzshim.conf`, the state
   directory, the pre-migration `American/*` legacy files under
   `/usr/local/share/zoneinfo/` (if any), and the destination
   `Canadian/*` files (usually empty at this point). Backup goes into
   a `mktemp -d` directory in `/tmp`.
2. **`update_scripts`** — copy `lib/patch_tzif.py`,
   `lib/reapply.sh`, `lib/custom_zones.sh`, `lib/upgrade.sh`, and
   `zones.conf` into their runtime locations. System-scope targets
   `/usr/local/libexec/canadian-tz-shim/` and
   `/usr/local/share/canadian-tz-shim/`.
3. **`generate_custom_zones`** — for every row in `zones.conf`,
   invoke `custom_zones_install`. That helper:
   - Copies the IANA source file from `/usr/share/zoneinfo/`.
   - Runs `lib/patch_tzif.py` (NUL-bounded pool matching, era-verified
     abbreviations, refuses multi-match pools).
   - Validates the result structurally (RFC 8536 header walk) and
     against fixed historical dates.
   - Stages inside `/usr/share/zoneinfo/Canadian/.<id>.tmp.XXXXXX` so
     the final rename is same-filesystem and atomic.
   - Refuses to overwrite a `Canadian/*` file the shim didn't create
     (checked against the manifest's recorded sha256).
4. **`relink_localtime_to_custom`** — repoints `/etc/localtime` to
   `/usr/share/zoneinfo/Canadian/<X>` derived from the current
   selected source. Records the pairing on a scratch file the next
   step picks up.
5. **`update_state_model`** — writes
   `selected-source-zone` and `selected-custom-zone` (two separate
   state fields in the 2.x model), removes the 1.x single-field
   `selected-zone`, and bumps `schema_version=2` in the config file.
   Records the exact `zone.tab` / `zone1970.tab` lines added into
   `custom-zones.json` for reversible uninstall.
6. **`install_systemd`** — refreshes the path and service unit files,
   runs `systemctl daemon-reload`, and enables/starts the watcher.
7. **`remove_legacy_zoneinfo`** — deletes the pre-migration
   `/usr/local/share/zoneinfo/America/*` files **only** when their
   abbreviation pool matches one of the shim's `OFFICIAL_ABBREV`
   values and lacks the source's IANA abbreviation. Any other file
   at that path is preserved.
8. **`validate_installation`** — re-runs structural validation on
   every managed file.

## Rollback

Any operation returning non-zero triggers
`restore_upgrade_backup`. Rollback restores:

- The pre-migration `/etc/tzshim.conf`.
- The pre-migration state directory (including the legacy
  `selected-zone` file if that's what existed).
- Any `/usr/local/share/zoneinfo/America/*` files the transaction
  removed during step 7.
- The pre-migration `/etc/localtime` symlink target.
- Deletes every `Canadian/*` file the transaction created (unless
  they existed before).

The rollback directory is preserved on disk if the restore itself
fails, and the operator is told the path so they can complete it
manually.

## Concurrent operation protection

`acquire_upgrade_lock` uses a lock file under
`/tmp/canadian-tz-shim-upgrade.lock`. Every return path releases it
explicitly — the library deliberately does not install an `EXIT`
trap, because doing so would clobber the caller's own trap. This is
verified by `test-regressions.sh` R6.

## Original-timezone metadata

The metadata written once on first install (`original_timezone` or
`original_timezone_path`) is **preserved across every subsequent
install, upgrade, and re-install.** Only `uninstall.sh` clears it,
and `uninstall.sh` refuses to complete restoration if the recorded
target is missing.

The 2.0.0 upgrade specifically rejects self-referential
`original_timezone_path` values that would point `/etc/localtime`
into the shim's own territory (e.g. a 1.x layout pointing at
`/usr/local/share/zoneinfo/America/Vancouver`). It then falls back
to detecting the current zone from the actual symlink's IANA suffix.

## Legacy version handling

Installs that predate version metadata (0.7.x and earlier) are
detected by "managed files exist but the config has no
`installed_version`". They are treated as being at
`minimum_version` from `migrations.json` (currently `0.8.0`) and
migrated forward one step at a time through the BFS path.

## Testing

The upgrade framework has three layers of coverage:

- **`test-upgrade.sh`** — 13 checks for the discovery and
  state-classification logic (current, upgradeable, legacy,
  corrupted, missing, not_installed, unsupported, downgrade).
- **`test-regressions.sh`** — R11 verifies `create_upgrade_backup`
  captures all six source files with the directory structure
  preserved; R6 asserts the library does not install an `EXIT` trap.
- **`test-migration.sh`** — 30 assertions executed inside a private
  mount + user namespace: seeds a realistic 1.x install, runs
  `install.sh --upgrade`, then checks that `Canadian/*` files exist
  with matching hashes in the manifest, `/etc/localtime` points at
  the custom identifier, `selected-source-zone` and
  `selected-custom-zone` both exist and are correct, the legacy
  `selected-zone` file is retired, `original_timezone` metadata is
  preserved, `schema_version` and `installed_version` are bumped,
  the 1.x patched files under `/usr/local/share/zoneinfo/America/`
  are gone, the `zone.tab` and `zone1970.tab` lines are present and
  idempotent under a second `--upgrade`, and a Qt 6 probe confirms
  `QTimeZone("Canadian/PCT").country() == Canada` and
  `comment()` starts with the correct abbreviation.

## Post-upgrade action for KDE

Because Qt parses `zone.tab` once at process startup, **KDE Plasma
needs a one-time plasmashell restart after any upgrade that changes
the tab entries** so the digital clock picks up the new country and
comment metadata:

```bash
systemctl --user restart plasma-plasmashell.service
```

That's the only manual step. No KDE configuration file needs editing.
