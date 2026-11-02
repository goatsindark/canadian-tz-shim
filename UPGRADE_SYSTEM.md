# Canadian Timezone Shim - Upgrade System Documentation

## Overview

The Canadian Timezone Shim includes a comprehensive version-aware upgrade system that safely migr installations between versions while preserving user configuration and ensuring system integrity.

## Key Features

- **Version Detection**: Automatically detects installed version and determines upgrade path
- **Safe Migration**: Preserves original timezone metadata and user selections
- **Rollback Support**: Automatic rollback on upgrade failure
- **Dry Run Mode**: Preview upgrade actions without making changes
- **Concurrent Operation Protection**: Lock mechanism prevents conflicting operations
- **Legacy Support**: Handles upgrades from older versions without version metadata

## Usage

### Checking Upgrade Status

```bash
# Check if upgrade is available (dry run)
./install.sh --upgrade --dry-run

# This will show:
# - Current installed version
# - Available upgrade path
# - Planned migration operations
# - Any blockers or issues
```

### Performing an Upgrade

```bash
# Upgrade to latest version
./install.sh --upgrade

# The upgrade process will:
# 1. Detect current installation state
# 2. Validate upgrade path
# 3. Create backup for rollback
# 4. Execute migration operations
# 5. Validate result
# 6. Update version metadata
```

### Upgrade States

The upgrade system detects the following states:

- **current**: Installation is up-to-date and healthy
- **upgrade_available**: Newer version available with valid migration path
- **repair_required**: Installation is damaged or incomplete
- **unsupported**: No valid migration path exists
- **not_installed**: No existing installation detected
- **ambiguous**: Installation state cannot be determined

## Migration Manifest

The upgrade system uses `migrations.json` to define supported upgrade paths:

```json
{
  "version": "1.0",
  "current_release": "1.0.0",
  "schema_version": "1",
  "migrations": [
    {
      "from_version": "0.9.0",
      "to_version": "1.0.0",
      "description": "Upgrade from 0.9.0 to 1.0.0",
      "schema_changes": [...],
      "file_changes": [...],
      "operations": [...],
      "validation": [...],
      "rollback": [...]
    }
  ]
}
```

### Migration Operations

Supported operation types:

- `backup_metadata`: Backup configuration files
- `migrate_config`: Update configuration format
- `update_scripts`: Replace library scripts
- `install_systemd`: Install systemd services
- `validate_installation`: Verify installation integrity

## Safety Features

### 1. Backup and Rollback

Before any migration:
- Configuration files are backed up
- Timezone files are backed up
- State directory is backed up

On failure:
- Automatic rollback to backup
- Original state is fully restored
- Clear error messages

### 2. Validation

Post-upgrade validation checks:
- All timezone files are valid
- Configuration is correct
- Version metadata is updated
- Installation is healthy

### 3. Locking

Concurrent operation protection:
- Lock file prevents multiple upgrades
- Stale lock detection
- Automatic cleanup on completion

### 4. Metadata Preservation

User data is always preserved:
- Original timezone selection
- Selected active zone
- User preferences

## Version Tracking

### Configuration Schema

Version 1.0.0 configuration format:

```bash
# /etc/tzshim.conf (system-wide)
# ~/.config/tzshim.conf (user mode)

original_timezone=America/Los_Angeles
installed_version=1.0.0
schema_version=1
```

### Legacy Versions

**Version 0.9.0 and earlier**:
- No version tracking
- Used `original_tz` instead of `original_timezone`
- No schema version field

The upgrade system automatically handles these legacy formats.

## Testing

### Test Coverage

The upgrade system includes comprehensive tests:

1. **Detection Tests**: Verify correct state detection
   - Current installation
   - Upgradeable installation
   - Legacy installation
   - Corrupted installation
   - Missing files
   - Not installed

2. **Safety Tests**: Verify safe operation
   - Dry run makes no modifications
   - Metadata preservation
   - Version tracking
   - Locking mechanism

3. **Edge Cases**: Verify error handling
   - Unsupported upgrade paths
   - Downgrade rejection
   - Concurrent operations

### Running Tests

```bash
# Run all upgrade tests
./test-upgrade.sh

# Tests use isolated fixtures and don't modify host system
```

## Upgrade Paths

### Supported Paths

- 0.8.0 → 1.0.0 (Legacy upgrade)
- 0.9.0 → 1.0.0 (Standard upgrade)
- 1.0.0 → 1.0.0 (No-op, already current)

### Unsupported Paths

- Downgrades (e.g., 1.0.0 → 0.9.0)
- Skipping major versions (if defined)
- Unknown source versions

## Troubleshooting

### Upgrade Fails with "No upgrade path available"

**Cause**: No migration path exists from current version

**Solution**: 
- Check `migrations.json` for supported paths
- Consider manual uninstall and reinstall

### Upgrade Fails with "Installation state ambiguous"

**Cause**: Installation metadata is corrupted or incomplete

**Solution**:
- Run `./install.sh --upgrade --dry-run` for details
- Consider manual repair or reinstall

### Lock File Errors

**Cause**: Another upgrade operation is in progress or stale lock

**Solution**:
- Check for running upgrade processes: `ps aux | grep canadian-tz-shim`
- Remove stale lock: `rm /tmp/canadian-tz-shim-upgrade.lock`

### Rollback Occurred

**Cause**: Upgrade validation failed

**Solution**:
- Check logs for specific validation failures
- Verify timezone files are not corrupted
- Try upgrade again after fixing underlying issue

## Architecture

### Components

1. **lib/upgrade.sh**: Core upgrade logic
   - Installation discovery
   - Upgrade decision engine
   - Migration execution
   - Rollback handling

2. **migrations.json**: Migration manifest
   - Defines supported paths
   - Specifies operations
   - Lists validation checks

3. **install.sh**: Integration point
   - Parses `--upgrade` flag
   - Calls upgrade library
   - Handles user interaction

### Data Flow

```
1. Discovery Phase
   └─> Read configuration
   └─> Check managed files
   └─> Validate installation health

2. Decision Phase
   └─> Compare versions
   └─> Find migration path
   └─> Determine action

3. Execution Phase
   └─> Acquire lock
   └─> Create backup
   └─> Execute operations
   └─> Validate result
   └─> Update metadata or rollback

4. Cleanup Phase
   └─> Release lock
   └─> Remove backup (on success)
```

## Best Practices

### Before Upgrading

1. Review dry-run output: `./install.sh --upgrade --dry-run`
2. Ensure no other upgrade operations are running
3. Verify sufficient disk space for backups
4. Check system logs for any existing issues

### During Upgrade

1. Don't interrupt the upgrade process
2. Monitor output for errors or warnings
3. Keep terminal open until completion

### After Upgrade

1. Verify timezone is correct: `date +"%Z %z"`
2. Check version: `cat /etc/tzshim.conf | grep installed_version`
3. Monitor system logs for any issues
4. Test timezone-dependent applications

## Future Enhancements

Potential improvements for future versions:

- Multi-hop upgrades (0.8.0 → 0.9.0 → 1.0.0)
- Incremental backups to save space
- Progress indicators for long operations
- Configuration migration validation
- Automatic retry on transient failures

## Support

For issues or questions:
1. Check this documentation
2. Run `./install.sh --upgrade --dry-run` for diagnostics
3. Review system logs: `journalctl -u canadian-tz-shim`
4. Check test output for clues

## Version History

- **1.0.0**: Initial release with upgrade system
- **0.9.0**: Pre-version tracking release
- **0.8.0**: Legacy release with different config format
