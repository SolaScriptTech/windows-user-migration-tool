# About

Windows User Migration Tool is a reusable PowerShell utility for technicians who need to preserve a Windows user's common files and selected preferences before replacing or rebuilding a workstation.

The original script was created for a specific environment. This public edition removes organization-specific infrastructure, repairs corrupted expressions, separates configuration from code, adds validation, and avoids destructive cleanup behavior.

## Design goals

- Safe defaults
- Transparent configuration
- Useful logging
- Resumable file copies through Robocopy
- No embedded private infrastructure
- Easy adaptation without editing the script

## Scope

This project collects migration data. It does not restore data automatically, manage cloud profiles, bypass access controls, or replace an enterprise backup system.
