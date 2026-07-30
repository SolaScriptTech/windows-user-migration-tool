# Windows User Migration Tool

A configurable PowerShell utility for backing up Windows user files and selected Windows settings during workstation or profile migrations.

The project was extracted from a larger code archive, repaired, and redesigned so it can be shared publicly without organization-specific infrastructure details.

## What it backs up

- Desktop, Documents, and Downloads
- Mapped network drives
- Network printer inventory
- Chrome bookmarks
- Google Earth data
- Snagit data
- Microsoft Sticky Notes
- Quick Access data
- An optional registry key configured by the operator

## Safety improvements

- No organization names, domains, servers, shares, or security groups are embedded in the script.
- Existing destination folders are archived with a timestamp instead of overwritten.
- Source data is never deleted.
- Potentially privileged ACL changes are disabled unless explicitly configured.
- `-WhatIf` is supported for a dry run.
- Robocopy exit codes are checked and failures are reported.
- Configuration is validated before copying begins.

> This is an administrative migration helper, not a complete backup product. Test it in a non-production environment and review the configuration before use.

## Requirements

- Windows 10 or later
- Windows PowerShell 5.1 or PowerShell 7
- `robocopy.exe`
- Access to the configured destination
- Administrator rights only when selected settings require them

## Quick start

1. Copy `config.example.json` to `config.json`.
2. Change `destinationRoot` to a location you control.
3. Review every optional setting.
4. Preview the run:

```powershell
.\src\WindowsUserMigration.ps1 -ConfigPath .\config.json -Mode Both -WhatIf
```

5. Run the migration:

```powershell
.\src\WindowsUserMigration.ps1 -ConfigPath .\config.json -Mode Both
```

Valid modes are `Folders`, `Settings`, and `Both`.

## Configuration

See [config.example.json](config.example.json). Paths may be local drives or UNC paths. Environment variables such as `%USERNAME%` are expanded.

The optional `roamingProfileAcl` section is disabled by default. Enable it only if you understand the target share's permission model.

## Output

Each run creates a user-specific folder beneath `destinationRoot` and writes `migration.log` there. If that folder already exists, it is renamed with a UTC timestamp before the new run begins.

## Security

Do not commit a real `config.json` containing internal paths or names. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
