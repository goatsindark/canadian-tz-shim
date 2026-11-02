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
- **Version-aware upgrades** - Safely upgrade between versions with automatic rollback
- **Idempotent installation** - Safe to run multiple times, preserves original timezone metadata
- **System-wide or user-level** - Install for all users or just your account
- **Complete coverage** - All 6 Canadian zones that diverged from IANA
- **Safe uninstallation** - Only removes files created by the shim, preserves unrelated files
- **Partial installation protection** - Only activates successfully patched zones

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

## Upgrading

The shim includes a version-aware upgrade system that safely migrates installations between versions.

### Checking for Upgrades

```bash
# Check if upgrade is available (dry run)
./install.sh --upgrade --dry-run
```

This will show:
- Current installed version
- Available upgrade path
- Planned migration operations
- Any blockers or issues

### Performing an Upgrade

```bash
# Upgrade to latest version
./install.sh --upgrade

# For system-wide installation
sudo ./install.sh --upgrade
```

The upgrade process will:
1. Detect current installation state
2. Validate upgrade path
3. Create backup for rollback
4. Execute migration operations
5. Validate result
6. Update version metadata

### Upgrade Safety

The upgrade system includes multiple safety features:

- **Automatic rollback** on failure
- **Metadata preservation** (original timezone, user selections)
- **Concurrent operation protection** via locking
- **Validation** before and after migration
- **Legacy support** for older versions without version tracking

See [UPGRADE_SYSTEM.md](UPGRADE_SYSTEM.md) for detailed documentation.

## How It Works

### TZif-Aware Binary Patching

The tool uses a Python-based TZif-aware patcher that surgically modifies only the timezone abbreviation fields:

1. Parses the TZif binary structure to locate abbreviation pools
2. Replaces the IANA abbreviation (e.g., `MST`) with the official abbreviation (e.g., `PCT`) in:
   - v1 abbreviation pool (32-bit TZif)
   - v2 abbreviation pool (64-bit TZif)
   - POSIX footer string
3. Validates file integrity after patching
4. Verifies UTC offsets and transition rules

This approach:
- Preserves all historical timezone transitions (PST/PDT before Nov 2026, PCT after)
- Maintains correct UTC offsets (UTC-7 year-round after the change)
- Handles POSIX timezone strings at the end of the file
- Works for all dates (past, present, and future)
- Does not modify unrelated binary data

**Important:** The TZif-aware patcher is the only supported patching method. There is no fallback to global string replacement.

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

The installer stores your timezone selection and original timezone metadata:

- System-wide:
  - Selected zone: `/var/lib/canadian-tz-shim/selected-zone`
  - Original timezone: `/etc/tzshim.conf`
- User-level:
  - Selected zone: `~/.local/state/canadian-tz-shim/selected-zone`
  - Original timezone: `~/.config/tzshim.conf`

This allows the systemd service to know which timezone to re-apply after updates, and enables clean uninstallation by restoring the original timezone.

**Important:** The original timezone metadata is preserved across reinstallation. Running the installer multiple times will not overwrite the saved original timezone.

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
3. Restore `/etc/localtime` to the original system timezone (saved during installation)
4. Remove only the patched timezone files (preserves unrelated files)
5. Remove state directory and configuration files

**Safety features:**
- Only removes files created by the shim
- Preserves unrelated files in the same directories
- Restores original timezone before removing files
- If restoration fails, keeps timezone files to avoid breaking the system

### User-level

```bash
./uninstall.sh
```

Remove the `TZ` export from your shell profile if you added it.

## Technical Details

### Why TZif-Aware Patching?

The shim uses a Python-based TZif-aware patcher instead of simple string replacement because:

- **Safety**: Only modifies known abbreviation locations in the TZif structure
- **Correctness**: Validates file integrity and UTC offsets after patching
- **Reliability**: No risk of corrupting unrelated binary data
- **Maintainability**: Clear separation between patching logic and installation logic

The alternative approach (global string replacement) could theoretically corrupt data if the abbreviation sequence appears elsewhere in the TZif structure. The TZif-aware patcher eliminates this risk.

### TZif Structure Awareness

The patcher understands the TZif binary format and modifies only:

1. **v1 abbreviation pool** - 32-bit timezone data
2. **v2 abbreviation pool** - 64-bit timezone data
3. **POSIX footer string** - Future timezone rules

All other binary data (transition times, UTC offsets, DST rules) remains untouched. The patcher validates that:

- File size is unchanged
- File structure is valid
- UTC offsets are correct
- Abbreviations appear in the expected dates

### Partial Installation Protection

The installer tracks which zones were successfully patched and only activates those. If a zone fails to patch:

- The failed zone file is removed
- Other successfully patched zones remain active
- The user is warned about the partial installation
- No broken `/etc/localtime` references are created

This ensures the system always has a working timezone configuration.

## Testing

Run the comprehensive test suite:

```bash
# Main test suite (installation, timezone correctness, safety)
./test.sh

# Upgrade system tests
./test-upgrade.sh

# Uninstall edge case tests
./test-uninstall-edge-cases.sh
```

For system-wide installation tests (requires root):

```bash
sudo ./test.sh --system
```

The test suite validates:

### Installation Lifecycle
- Initial installation and repeated installation
- Preservation of original-timezone metadata across reinstalls
- Idempotency (safe to run multiple times)
- Partial installation protection

### Upgrade System
- Upgrade detection (current, upgradeable, legacy, corrupted, missing, not installed)
- Dry run mode (no modifications)
- Metadata preservation during upgrade
- Version tracking after upgrade
- Locking mechanism for concurrent operations
- Unsupported upgrade path rejection
- Downgrade rejection

### Timezone Correctness
- Historical timezone transitions (1900-2026)
- Future timezone transitions (2026-2100+)
- Exact transition boundaries (second-level precision)
- POSIX timezone strings
- UTC offset validation

### Safety Features
- Safe uninstallation (only removes shim files)
- Original timezone restoration
- Preservation of unrelated files
- Failed patch cleanup
- Legacy installation handling

### System Integration (system mode only)
- Systemd service reapplication
- State file management
- Configuration file preservation

The test suite uses isolated temporary directories and does not modify the host's real `/etc/localtime` during automated tests.

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
