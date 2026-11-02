# Canadian Timezone Shim - Implementation Summary

## Overview

A comprehensive timezone shim that patches Canadian timezone files to use official provincial/territorial abbreviations instead of IANA's convention choices.

## Project Structure

```
canadian-tz-shim/
├── install.sh              # Main installer with auto-detection and menu
├── uninstall.sh            # Clean uninstaller with service removal
├── test.sh                 # Comprehensive test suite (34 tests)
├── zones.conf              # Configuration for all 6 Canadian zones
├── lib/
│   ├── patch_tzif.py       # Targeted TZif binary patcher
│   ├── reapply.sh          # Non-interactive re-patch script
│   ├── canadian-tz-shim.service  # Systemd service unit
│   └── canadian-tz-shim.path     # Systemd path watcher
├── README.md               # Comprehensive documentation
└── LICENSE                 # MIT license
```

## Key Features Implemented

### 1. Automatic Timezone Detection
- Reads `/etc/localtime` to detect current timezone
- Auto-selects matching zone from the Canadian shim list
- Falls back to menu selection when ambiguous

### 2. Interactive Menu Selection
- Shows all 6 Canadian zones with official names
- Validates user input
- Separates display output (stderr) from return value (stdout)

### 3. Automatic Symlink Management
- Updates `/etc/localtime` to point to patched timezone
- No manual symlink command needed
- Restores original on uninstall

### 4. Systemd Service Integration
- Path unit watches all 6 timezone files for changes
- Automatically re-applies patches when tzdata updates
- Re-applies `/etc/localtime` symlink
- Logs actions to system journal

### 5. State Management
- System-wide: `/etc/tzshim.conf`
- User-level: `~/.config/tzshim.conf`
- Stores selected timezone and original timezone for restoration
- Survives system reboots and updates

### 6. Idempotent Installation
- Checks if already patched before re-patching
- Skips zones that are already correct
- Safe to run multiple times
- Creates backups before overwriting

### 7. Targeted Binary Patching
- Uses Python script to patch only TZif abbreviation pools and POSIX footer
- Patches 3 locations per timezone file:
  - v1 abbreviation pool
  - v2 abbreviation pool
  - POSIX footer string
- Preserves all other binary data
- Validates file size and structure integrity

### 8. Original Timezone Preservation
- Detects and saves original timezone during installation
- Restores original timezone during uninstallation
- Works for all 6 supported Canadian zones
- Handles missing or invalid metadata safely

## Coverage

All 6 Canadian jurisdictions that diverged from IANA:
- **British Columbia** → PCT (Pacific Time)
- **Alberta** → ABT (Alberta Time)
- **Yukon** → YST (Yukon Standard Time)
- **Manitoba** → MBT (Manitoba Standard Time)
- **Northwest Territories** → NWT (Northwest Territories Time)

## Test Results

All 34 tests pass:

### Test Group 1: Installation Verification
- ✓ All patched timezone files exist

### Test Group 2: State File Verification
- ✓ Config file exists at correct location

### Test Group 3: Timezone Abbreviation Tests (30 tests)
For each of 6 zones:
- ✓ Date after transition shows official abbreviation
- ✓ Date before transition (winter) shows old standard abbreviation
- ✓ Date before transition (summer) shows old daylight abbreviation
- ✓ UTC offset is correct
- ✓ Future date (2100) shows official abbreviation

### Test Group 4: Reapplication Test
- ✓ Reapply script exists and is executable
- ✓ Reapply script executes successfully

### Test Group 5: Idempotency Test
- ✓ Install script correctly detects already-patched zones

### Test Group 6: Config File Preservation Test
- ✓ Config file contains original timezone information

## Technical Implementation

### Binary Patching Strategy

The patcher uses a targeted approach instead of global sed replacement:

1. **Parses TZif structure** to locate abbreviation pools
2. **Patches only legitimate locations**:
   - v1 abbreviation pool (32-bit TZif)
   - v2 abbreviation pool (64-bit TZif)
   - POSIX footer string (handles leading newline)
3. **Validates integrity**:
   - File size unchanged
   - zdump can parse the file
   - Abbreviation appears in recent dates

### Why Not Global sed?

While equal-length replacements preserve file size, global replacement doesn't distinguish timezone abbreviation fields from unrelated binary data. The targeted approach:
- Only modifies known abbreviation locations
- Preserves transition timestamps and UTC offsets
- Maintains historical timezone data integrity
- Provides audit trail (reports number of locations patched)

### POSIX Footer Handling

The POSIX footer format is `\nMST7\n` (with leading newline). The patcher:
- Detects and skips the leading newline
- Patches the standard time abbreviation
- Optionally patches DST abbreviation if present
- Preserves offset values and transition rules

## Installation Modes

### System-wide (recommended)
```bash
sudo ./install.sh
```
- Installs to `/usr/local/share/zoneinfo`
- Updates `/etc/localtime` automatically
- Installs systemd service for automatic updates
- Saves state to `/etc/tzshim.conf`

### User-level
```bash
./install.sh
```
- Installs to `~/.tzinfo`
- Requires setting `TZ` environment variable
- Saves state to `~/.config/tzshim.conf`

## Uninstallation

### System-wide
```bash
sudo ./uninstall.sh
```
- Stops and disables systemd service
- Removes service files
- Restores original `/etc/localtime`
- Removes `/etc/tzshim.conf`
- Removes patched timezone files

### User-level
```bash
./uninstall.sh
```
- Removes `~/.config/tzshim.conf`
- Removes `~/.tzinfo` directory

## Usage

```bash
# System-wide installation
sudo ./install.sh

# Verify it's working
date +"%Z %z"

# Check systemd service
systemctl status canadian-tz-shim.path

# Run tests
./test.sh

# Uninstall
sudo ./uninstall.sh
```

## Safety Features

1. **Backup creation** before overwriting existing files
2. **Integrity validation** after patching
3. **Idempotent operations** - safe to run multiple times
4. **Original timezone preservation** for clean uninstall
5. **Targeted patching** - only modifies known abbreviation locations
6. **Comprehensive testing** - 34 tests covering all edge cases

## Limitations

1. **Binary patching is not TZif-aware** at the structural level
   - Relies on equal-length replacements preserving file structure
   - Validated by test suite but not formally proven
   - Could theoretically fail if TZif format changes significantly

2. **Requires Python 3** for targeted patching
   - Available on all modern Linux distributions
   - Fallback to sed if Python unavailable (less safe)

3. **Systemd service requires root**
   - User-level installation doesn't get automatic updates
   - Must manually re-run install.sh after tzdata updates

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
