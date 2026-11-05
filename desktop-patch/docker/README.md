# Desktop Adapter Integration Harness (Docker)

Container-based verification for the six desktops that aren't the
developer's live environment: GNOME, Cinnamon, MATE, Budgie, XFCE,
LXQt. The matrix is opt-in, development-only, and excluded from the
shipped release archive (see *Release packaging* in
[`../../DESKTOP_COMPANION_IMPLEMENTATION.md`](../../DESKTOP_COMPANION_IMPLEMENTATION.md)).

Result of a full run against the shipped Dockerfiles:

```
GNOME     PASS  (5/0 checks, integration verified)
Cinnamon  PASS  (4/0 checks, integration verified)
MATE      PASS  (4/0 checks, integration verified)
Budgie    PASS  (5/0 checks, integration verified)
XFCE      PASS  (10/0 checks, integration verified)
LXQt      PASS  (23/0 checks, fixture verified against the shipped default panel.conf)
```

## What these containers verify

**Only the specific configuration path each desktop's clock widget
uses.** Nothing else. No full DE is installed — just enough of each
desktop's settings backend for its clock widget's storage to behave
as it would on a live session.

| Desktop  | Packages installed                                                                                                            |
|----------|-------------------------------------------------------------------------------------------------------------------------------|
| GNOME    | `gsettings-desktop-schemas`, `dconf-cli`, `dconf-gsettings-backend`, `libglib2.0-bin`, `dbus` + session                        |
| Cinnamon | `cinnamon-desktop-data`, plus the same GSettings + dconf stack                                                                |
| MATE     | `mate-settings-daemon`, `mate-panel`, plus the same GSettings + dconf stack                                                    |
| Budgie   | Same as GNOME (Budgie's clock uses `org.gnome.desktop.datetime`)                                                               |
| XFCE     | `xfce4-panel`, `xfce4-settings`, `xfconf`, plus `dbus` + session                                                              |
| LXQt     | `lxqt-panel`, plus `dconf-cli` and Python                                                                                        |

Each container:

1. **Copies the whole repository** into `/opt/canadian-tz-shim`.
2. **Preseeds `/etc/localtime`** with the unpatched `America/Vancouver`
   symlink so `install.sh`'s auto-detection succeeds non-interactively
   inside the container.
3. **Runs `install.sh` as root** at build time. That installs the
   real `Canadian/*` TZif files under the container's
   `/usr/share/zoneinfo/Canadian/` and appends the corresponding
   `zone.tab` / `zone1970.tab` registration lines.
4. **At container start**, the entrypoint drops privileges to an
   unprivileged `dtp` user via `setpriv`, sets up an isolated
   `/tmp/dtp-home`, and (for GSettings and Xfconf desktops) wraps the
   check in `dbus-run-session` so all writes go to a private bus
   rather than any host session bus.
5. **Runs the check script.** Each check verifies the desktop's real
   settings backend exposes (or correctly does not expose) an
   explicit per-user timezone key, that the custom identifier is
   discoverable through the same backend, and that the companion
   behaves correctly for that desktop's situation.

## The two legitimate integration outcomes

Not every desktop has an explicit per-user timezone setting to
rewrite. Both outcomes are valid and expected; the harness treats
them equally.

### Path 1 — Explicit setting present

The check seeds the desktop's own storage with
`America/Vancouver`, runs the companion with `--dry-run` (asserting
no writes), then runs it for real (asserting the stored value becomes
`Canadian/PCT`), then asserts sibling keys are untouched, then runs
`--restore` (asserting the value goes back to `America/Vancouver`).

**Currently follows this path:** XFCE (real Xfconf D-Bus service,
`/plugins/plugin-<N>` discovered as string `"clock"`, its
`Timezone` property round-tripped), LXQt (real top-level widget
section `[clock]` in `~/.config/lxqt/panel.conf`, `timezone=` inside
that section round-tripped). Would also follow this path for KDE if
the digital clock had been left in `Selected` mode with an explicit
IANA id — the live KDE row uses `Local` mode, so the write is not
required.

### Path 2 — No explicit key, follows `/etc/localtime`

The check confirms the desktop's real settings schema set contains no
per-user timezone string key. It then verifies the desktop's own
runtime (glibc, Qt, GLib, whatever the desktop uses) resolves
`Canadian/PCT` to the correct abbreviation at fixed dates via the
system `zoneinfo` directory. The correct outcome in this branch is
that the companion writes nothing, and the check **passes** for
having verified that.

**Currently follows this path:** GNOME, Cinnamon, MATE, Budgie. On
Debian trixie, none of the four ships a per-user `timezone` key in
their gsettings schemas — they rely on `timedatectl` / the system
zone, which the core installer repoints.

## Actual desktop layouts the checks exercise

**XFCE.** The clock plugin is discovered by listing the
`xfce4-panel` Xfconf channel and looking at each
`/plugins/plugin-<N>` string property; a plugin whose value is
`clock` is a clock instance. The zone id lives at
`/plugins/plugin-<N>/Timezone` (capital T, string). The adapter uses
that exact path and case — `xfconf-query -c xfce4-panel -p
/plugins/plugin-3/Timezone -s Canadian/PCT` round-trips against a
real `xfsettingsd` inside the container.

**LXQt.** Real LXQt `panel.conf` files list widgets as top-level
INI sections. A minimal file looks like:

```ini
panels=panel1

[panel1]
plugins=fancymenu,quicklaunch,clock,tray
position=Bottom

[fancymenu]
type=fancymenu

[clock]
type=clock
timezone=America/Vancouver

[tray]
type=tray
```

The clock widget's section is named after the entry in the parent's
`plugins=` list. `type=clock` (and, for the alternate widget,
`type=worldclock`) is what marks a section as a clock. The
`timezone=` key lives directly inside the widget's own section. The
check seeds this exact shape — taken from the real
`/usr/share/lxqt/panel.conf` Debian ships — and asserts the adapter
rewrites only the `timezone=` line inside `[clock]` (or
`[worldclock]`) while preserving every other widget's section header,
`type=` field, alignment, and formatting key byte-for-byte.

**GNOME / Cinnamon / MATE / Budgie.** Each check queries the actual
GSettings schema list installed by the desktop's real package set and
confirms no per-user `timezone` string key is present in the
datetime-adjacent schemas on Debian trixie.

## What these containers do not verify

- The rendered panel or applet on screen. No display server, no
  compositor, no window manager, no visual snapshotting.
- The exact repaint cadence, tooltip rendering, or theming.
- Whether a widget-level D-Bus notification (as opposed to file
  change) causes the applet to reload.

Rendering the correct abbreviation end-to-end in a live session is
verified separately for KDE by `live-kde-verify.sh` on the host and
by visual confirmation on the developer's machine after the one-time
`plasmashell` restart. For the other six desktops, the strongest
claim this harness supports is "the desktop's own stack, running
against its real schema or configuration service, resolves the
custom identifier correctly at fixed dates."

## Validation levels used across the repo

| Level       | Meaning                                                            |
|-------------|--------------------------------------------------------------------|
| Live        | Verified in a real desktop session with visual confirmation        |
| Integration | Verified against the desktop's own schema / configuration service, running inside a container with the real packaged components |
| Fixture     | Verified only against representative configuration files matching the desktop's shipped default format |
| Unsupported | The setting or data source could not be identified confidently     |

Each check script prints a per-desktop capability matrix at the end
with these fields:

```
recognized:                    yes/no/n/a
enumerated:                    yes/no
selectable:                    yes/no/n/a (no explicit gsettings key)
renders_expected_abbreviation: yes/no
validation_level:              live/integration/fixture/unsupported
checks: N passed, M failed
```

**"renders_expected_abbreviation = yes" on a container row** means
the desktop's own tzfile lookup resolves the custom identifier to the
expected abbreviation at the fixed test instant (e.g.
`TZ=Canadian/PCT date -d 2026-12-15` returns `PCT`). It does not
mean a running panel rendered it visually. Only KDE is live verified
in the stronger sense.

## Safety guarantees

Each container is launched by `run-tests.sh` as:

```
docker run --rm --network=none tzshim-check-<desktop>
```

Which gives:

- **No host filesystem mounts.** Only what the image `COPY`'d in is
  visible. Nothing under `$HOME`, `/etc`, or `/usr/share` on the
  developer's machine is exposed to the container.
- **No `--privileged`.** The container has the default Docker
  capability set (no `CAP_SYS_ADMIN`, no `CAP_SYS_PTRACE`, no host
  PID or IPC namespaces shared).
- **`--network=none`** — the check script itself has no network
  access. Note that image *builds* do need network (apt-get), so
  the build and the run are different stages; only the run is
  isolated.
- **No `--cap-drop=ALL`.** The entrypoint legitimately needs
  `SETGID`, `SETUID`, `CHOWN`, `FOWNER`, `DAC_OVERRIDE` to create
  the unprivileged `dtp` user and set up its HOME inside the
  container. Docker's default set is already the right level of
  privilege for a container that mounts nothing from the host.
  Over-aggressive capability drops surface as a confusing
  `groupadd: group 'dtp' already exists` error (which is what
  `groupadd` reports when its underlying syscall returns `EPERM`),
  not as a security improvement.
- **Unprivileged test user.** All check logic runs after
  `setpriv --reuid=$uid --regid=$uid --clear-groups`, so the
  adapter code sees an ordinary non-root session.
- **Private D-Bus session** where the backend requires it (GSettings
  writes on GNOME/Cinnamon/Budgie/MATE, Xfconf queries on XFCE).
  Started with `dbus-run-session`, which allocates a throwaway
  socket for the container's lifetime.
- **Isolated temporary HOME** at `/tmp/dtp-home`. Nothing under it
  escapes the container.
- **`--rm`** on every run, so containers and their writes are
  discarded after each check.

The core installer runs **inside the container's own
`/usr/share/zoneinfo/`** during image build. That is the
container's own tmpfs-backed zoneinfo directory. The developer's
real `/usr/share/zoneinfo/` is never exposed to the container and
never modified by anything in this harness.

## Running the matrix

Requires Docker with a working daemon and outbound HTTPS to
`deb.debian.org` (for the build; the test container itself is
network-isolated).

```bash
# All six desktops
./desktop-patch/docker/run-tests.sh

# A subset
./desktop-patch/docker/run-tests.sh gnome xfce

# Build images without running the checks
./desktop-patch/docker/run-tests.sh --build-only

# List supported desktops
./desktop-patch/docker/run-tests.sh --list
```

Each image takes a few minutes to build the first time (apt-get of
the desktop's schemas + Qt/GSettings tooling + running the core
installer). Subsequent runs reuse Docker's layer cache and only
re-execute the check script inside the existing image.

## Design constraints honoured (from the original brief)

- **Isolated temporary home directory** → `/tmp/dtp-home` owned by a
  fresh non-root user created by the entrypoint.
- **Unprivileged test user** → `setpriv --reuid=… --regid=…
  --clear-groups` before running any check logic.
- **Isolated D-Bus session where required** → `dbus-run-session` for
  the GSettings-family containers and the XFCE container. LXQt's
  config path is a plain INI file, so no D-Bus session is spun up
  there.
- **No access to the developer's real home directory** → no `-v` or
  `--mount` in `run-tests.sh`.
- **No access to the host's desktop session bus** → private
  `dbus-run-session`, no `-v /run/user/…` bind, and `--network=none`
  so no host D-Bus system bus reachable either.
- **No privileged mode** → default Docker capabilities only; no
  `--privileged`, no `--pid=host`, no `--net=host`.
- **No host configuration directories mounted writable** → no bind
  mounts at all.

## Files

```
docker/
├── README.md                             (this file)
├── run-tests.sh                          (top-level orchestrator)
├── common/
│   ├── entrypoint.sh                     (setpriv + dbus-run-session + HOME setup)
│   ├── check_lib.sh                      (assertion helpers + patch_apply/dry/restore)
│   └── gsettings_check.sh                (shared script for GNOME-family desktops)
├── gnome/Dockerfile
├── cinnamon/Dockerfile
├── mate/Dockerfile
├── budgie/Dockerfile
├── xfce/
│   ├── Dockerfile
│   └── check.sh                          (real Xfconf D-Bus round-trip)
└── lxqt/
    ├── Dockerfile
    └── check.sh                          (real shipped-default panel.conf)
```

`gnome`, `cinnamon`, `mate`, and `budgie` all share
`common/gsettings_check.sh` with different `SCHEMA`, `KEY`,
`ID_FORMAT`, and `HAS_EXPLICIT_KEY` env vars in their Dockerfile.
`HAS_EXPLICIT_KEY=0` tells the check "this desktop's real settings
stack, on this distro, exposes no per-user timezone key — assert
that and pass". `XFCE` and `LXQt` have their own `check.sh` because
their config mechanisms are structurally different.

## Known limitations of this harness

- **MATE / Cinnamon / Budgie on other distros.** The containers
  exercise Debian trixie's packaged desktop components. Upstream
  MATE and Cinnamon do ship per-user timezone keys in some distros;
  on Debian trixie the specific package set doesn't. That's a
  legitimate outcome, but it means "these follow the system tz" is
  verified only for this distribution. The GSettings-family check
  script is designed to detect either outcome: on a distro where the
  explicit key exists, `HAS_EXPLICIT_KEY` defaults to `1` and the
  full seed / apply / restore path runs.
- **LXQt is fixture-level, not integration.** The container installs
  the real `lxqt-panel` package so the `panel.conf` format is
  authoritative, but the harness never starts a running panel. If
  upstream LXQt changes the plugin section naming, the fixture would
  drift.
- **No visual verification.** No display server, no screenshot
  comparison, no Xvfb. Only the file/service round-trips are
  verified.
