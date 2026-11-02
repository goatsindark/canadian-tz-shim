# Canadian Timezone Shim

A user-space shim that patches Canadian timezone files to use official provincial/territorial abbreviations instead of IANA's convention choices.

## Background

Several Canadian provinces and territories have adopted permanent daylight saving time with official timezone names that differ from IANA's choices:

- **British Columbia** → Pacific Time (PCT) - IANA uses MST
- **Alberta** → Alberta Time (ABT) - IANA uses CST
- **Yukon** → Yukon Standard Time (YST) - IANA uses MST
- **Manitoba** → Manitoba Standard Time (MBT) - IANA uses EST
- **Northwest Territories** → Northwest Territories Time (NWT) - IANA uses CST

This tool patches your local timezone files to use the official abbreviations while preserving all historical timezone transitions and future rules.

## Features

- **Automatic timezone detection** - Detects your current timezone from `/etc/localtime`
- **Menu selection** - Prompts for timezone selection when detection is ambiguous
- **Automatic symlink management** - Updates `/etc/localtime` to point to patched timezone
- **Systemd service** - Automatically re-applies patches when tzdata package updates
- **Idempotent installation** - Safe to run multiple times
- **System-wide or user-level** - Install for all users or just your account
- **Complete coverage** - All 6 Canadian zones that diverged from IANA

## Installation

### System-wide (recommended)

```bash
sudo ./install.sh
```

The installer will:
1. Detect your current timezone from `/etc/localtime`
2. If detected, automatically select that timezone
3. If ambiguous, show a menu to select your timezone
4. Patch all timezone files
5. Update `/etc/localtime` to point to the patched timezone
6. Install a systemd service to watch for tzdata updates

### User-level only

```bash
./install.sh
```

This installs patched timezones to `~/.tzinfo/` and requires setting the `TZ` environment variable:

```bash
export TZ=~/.tzinfo/America/Vancouver
```

Add this to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) for persistence.

## How It Works

### Binary Patching

The tool performs binary patching on compiled zoneinfo files:

1. Copies `/usr/share/zoneinfo/America/Vancouver` to the target location
2. Searches for the IANA abbreviation (e.g., `MST`) in the binary data
3. Replaces it with the official abbreviation (e.g., `PCT`)
4. Both abbreviations are 3 bytes, so file size and offsets are preserved

This approach:
- Preserves all historical timezone transitions (PST/PDT before Nov 2026, PCT after)
- Maintains correct UTC offsets (UTC-7 year-round after the change)
- Handles POSIX timezone strings at the end of the file
- Works for all dates (past, present, and future)

### Automatic Updates

When installed system-wide, the shim includes a systemd path unit that monitors the system timezone files:

```
/usr/share/zoneinfo/America/Vancouver
/usr/share/zoneinfo/America/Edmonton
/usr/share/zoneinfo/America/Whitehorse
/usr/share/zoneinfo/America/Dawson
/usr/share/zoneinfo/America/Winnipeg
/usr/share/zoneinfo/America/Yellowknife
```

When any of these files change (e.g., after a tzdata package update), the systemd service automatically:
1. Re-patches the affected timezone file
2. Re-applies the `/etc/localtime` symlink
3. Logs the action to the system journal

This ensures your patched timezone survives system updates without manual intervention.

### State Management

The installer stores your timezone selection in a state file:

- System-wide: `/var/lib/canadian-tz-shim/selected-zone`
- User-level: `~/.local/state/canadian-tz-shim/selected-zone`

This allows the systemd service to know which timezone to re-apply after updates.

## Verification

After installation, verify the patch is working:

```bash
# Check current timezone abbreviation
date +"%Z %z"
# Should show: PCT -0700 (if Vancouver was selected)

# Test future dates
TZ=/usr/local/share/zoneinfo/America/Vancouver date -d "2100-06-15 12:00:00" +"%Y-%m-%d %H:%M:%S %Z %z"
# Expected: 2100-06-15 12:00:00 PCT -0700

# Test historical dates (before transition)
TZ=/usr/local/share/zoneinfo/America/Vancouver date -d "2025-01-15" +"%Y-%m-%d %Z %z"
# Expected: 2025-01-15 PST -0800

# Verify systemd service is running
systemctl status canadian-tz-shim.path
```

## Uninstallation

### System-wide

```bash
sudo ./uninstall.sh
```

This will:
1. Stop and disable the systemd service
2. Remove systemd service files
3. Restore `/etc/localtime` to the original system timezone
4. Remove patched timezone files
5. Remove state directory

### User-level

```bash
./uninstall.sh
```

Remove the `TZ` export from your shell profile if you added it.

## Technical Details

### Why Binary Patching?

The alternative approach would be to modify the IANA tzdata source files and recompile with `zic`. However:

- Requires `zic` and tzdata build toolchain
- More complex installation process
- Slower (compilation vs. instant binary patch)
- Harder to maintain across tzdata versions

Binary patching is simpler and works reliably for same-length replacements.

### TZif Structure Awareness

The global `sed` replacement isn't inherently aware of TZif structure. It replaces every occurrence of the 3-byte sequence, not just timezone abbreviations. In theory, this could corrupt data if the sequence appears elsewhere in the TZif structure.

In practice, for these specific timezone files:
- The abbreviations are the only 3-letter uppercase sequences that match
- The test suite validates dates across the full range (1900-2100+)
- Transition timing is exact

The test suite provides confidence, though it doesn't establish correctness for every possible date.

### Idempotency

The installer is idempotent:
- Checks if a timezone is already patched before re-patching
- Skips zones that are already correct
- Safe to run multiple times
- Creates backups before overwriting existing patched files

## Testing

Run the component tests:

```bash
./test-components.sh
```

Run the full test suite:

```bash
./test.sh
```

The test suite validates:
- Config file parsing (6 zones)
- Systemd service file format
- Systemd path file format
- Reapply script permissions
- Timezone detection logic
- State directory creation
- Patch idempotency
- Historical timezone transitions (1900-2026)
- Future timezone transitions (2026-2100+)
- POSIX timezone strings
- Exact transition timing

## References

- [BC Government: B.C.'s new time zone (Pacific time)](https://www.gov.bc.ca/gov/content/governments/celebrating-british-columbia/daylight-saving-time)
- [Alberta Government: Alberta's new time system (ABT)](https://www.alberta.ca/albertas-new-time-system-abt)
- [Yukon Government: Learn about Yukon Standard Time](https://yukon.ca/en/your-government/about-yukon/learn-about-yukon-standard-time)
- [Manitoba Government: No More Falling back](https://www.gov.mb.ca/timechange/)
- [NWT Government: Northwest Territories Time](https://gnwt.ca/sport-recreation-and-tourism/living-nwt/northwest-territories-time)
- [IANA Time Zone Database](https://www.iana.org/time-zones)

## License

MIT License - see LICENSE file for details.

## Disclaimer

This is an unofficial community tool. It is not endorsed by IANA, any provincial/territorial government, or any timezone authority. It exists to give users a choice in how they display timezone information.
