# New-LocalUser.ps1

A PowerShell utility that creates a new numbered local administrator account on the current machine. It derives a base name from the running user, finds the next available numbered username, prompts interactively for credentials, creates the account, and optionally configures a one-time auto-logon before logging off.

## Prerequisites

- **Windows PowerShell 5.1+**
- **Administrator elevation** (the script will refuse to run without it)
- **Microsoft.PowerShell.LocalAccounts module** — built into Windows; no installation required

## Quick Start (Recommended)

Use the auto-elevating launcher instead of invoking the script directly:

```powershell
pwsh -File scripts\Start-App.ps1
```

`Start-App.ps1` first checks installed copies for a newer GitHub release. If one is available, it runs the installer with the run prompt suppressed, relaunches the updated launcher, and exits the old copy. It then checks whether the current session is elevated. If not, it re-launches the main script via `Start-Process ... -Verb RunAs`, triggering a UAC prompt. If already elevated it calls `New-LocalUser.ps1` directly in the same session.

## Manual Invocation

If your session is already elevated you can call the script directly:

```powershell
# From an elevated PowerShell prompt at the solution root
.\src\Pwsh-NewLocalUser\New-LocalUser.ps1
```

Invoking without elevation will produce a red error and throw immediately.

## Password Configuration (.env file)

The script reads an optional `.env` file located at the solution root to pre-configure the password for new accounts.

### Setup

```powershell
# Copy the example and fill in your desired password
Copy-Item .env.example .env
notepad .env
```

`.env` format (see `.env.example`):

```
NEW_USER_PASSWORD=YourP@ssw0rd
```

`.env` is git-ignored and must never be committed.

### Runtime behaviour

| Situation | What happens |
|---|---|
| `.env` present, Enter pressed at password prompt | Password from `.env` is used silently |
| `.env` present, new password typed | Confirmation prompt shown; typed value used if they match |
| No `.env`, Enter pressed at password prompt | Error; loop repeats until a non-blank password is entered |
| No `.env`, non-blank password typed | Confirmation prompt shown; typed value used if they match |
| Passwords do not match | Error; loop repeats |

## Profile Migration Configuration

Before the auto-logon prompt, `New-LocalUser.ps1` checks `src/Pwsh-NewLocalUser/ProfileMigrationPatterns.json` for file-pattern rules to inspect inside the **current** user profile.

Default rules include:

- `Videos\ManyCam\*.mp4` (recursive)
- `Pictures\ManyCam\*.jpg` (recursive)
- `Pictures\Screenshots\*.png` (recursive)
- top-level `Videos\*.mp4` and `Videos\*.mkv`
- top-level `Downloads` content files: PDFs, Office documents, CSV/TSV/JSON data files, common image/video files, and ZIP archives
- `Downloads\Telegram Desktop` common image/video/archive files
- `Documents\ShareX\ScreenRecordings\*.mp4` (recursive)
- `Documents\ShareX\Screenshots` image/video/animation files (recursive)
- matching OneDrive variants for the ManyCam, Screenshots, and ShareX screenshot folders

If matches are found, the script displays grouped per-folder counts and prompts whether to migrate them for the new user after first sign-in.

## How It Works

The script runs in seven sequential phases:

1. **Elevation check** — calls `Test-IsElevated`; terminates immediately if not running as Administrator.

2. **Password resolution** — loads `NEW_USER_PASSWORD` from `.env` if present. Enters an interactive loop (see table above) until a valid `SecureString` password is confirmed.

3. **Username resolution** — strips trailing digits from `$env:USERNAME` to derive a base name (e.g., `erik80` → `erik`), then scans existing local accounts for names matching `^<base>\d+$` and increments the highest number by 1 (starts at 1 if none exist). Presents the suggested name via `Read-AppText` with a default answer. Loops if the input is blank or the name is already in use.

4. **Confirmation panel** — displays a `Show-AppSummary` summary showing the proposed username, fixed account properties, target group, and computer name. Prompts `Read-AppConfirm` — answering No aborts with no changes made.

5. **User creation** — runs inside `Invoke-AppStatus` (status line). Calls `New-LocalUser` with `PasswordNeverExpires` and `UserMayNotChangePassword` set, then `Add-LocalGroupMember -Group Administrators`. A failure in either cmdlet is fatal (`$ErrorActionPreference = 'Stop'`).

6. **Verification** — reads the account back with `Get-LocalUser` and confirms Administrators membership with `Get-LocalGroupMember`. Results are displayed in a `Format-Table`.

7. **Profile migration pre-check** — Uses `ProfileMigrationPatterns.json` to scan configured folders in the current profile. If matches are found and accepted, the script registers an `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce` entry (`!OSM_ProfileMigration` — the leading `!` keeps the entry until the command exits with code 0, so a denied UAC prompt does not lose the migration) that launches `Invoke-ProfileMigrationPostLogon.ps1` with `-PreviousUserName` and `-NewUserName` (plus config path) on the first logon.

8. **Auto-logon offer** — `Read-AppConfirm` asks whether to log on as the new account immediately. If confirmed, five registry keys are written under `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`:

   | Key | Value set |
   |---|---|
   | `AutoAdminLogon` | `1` |
   | `DefaultUserName` | new username |
   | `DefaultDomainName` | `$env:COMPUTERNAME` |
   | `DefaultPassword` | password (plain text, cleared from memory after write) |
   | `AutoLogonCount` | `1` (one-time only) |

   The script then calls `logoff` to end the current session.

## Account Properties

Every account created by this script has the following properties:

| Property | Value |
|---|---|
| Name | `<base><N>` (e.g., `erik1`) |
| Enabled | `True` |
| PasswordNeverExpires | `True` |
| UserMayNotChangePassword | `True` |
| Member of | `Administrators` (local) |

## Error Handling

`$ErrorActionPreference = 'Stop'` is set globally. All errors from `New-LocalUser` and `Add-LocalGroupMember` are fatal and will surface as terminating errors.

| Scenario | Behaviour |
|---|---|
| Not running as Administrator | Red error message + terminating throw; no UI is shown |
| Blank password with no `.env` | Red message; password loop repeats |
| Password confirmation mismatch | Red message; password loop repeats |
| Blank username entered | Red message; username loop repeats |
| Username already in use | Red message; username loop repeats |
| User cancels at confirmation prompt | Yellow abort message; no account created |
| `New-LocalUser` fails | Terminating error (fatal) |
| `Add-LocalGroupMember` fails | Terminating error (fatal) |

## Console UI

The script uses native ConsoleUI helpers (dot-sourced from `ConsoleUI.ps1`) for all interactive output:

| Element | Purpose |
|---|---|
| `Show-AppBanner` | "New Local User" banner at startup |
| `Show-AppRule` | Section dividers (Password, Username, Confirm, Verification) |
| `Write-AppHost` | Styled status and error messages (colored via `[color]...[/]` markup) |
| `Read-AppText` | Username prompt with pre-filled default answer |
| `Read-AppConfirm` | Yes/No prompts for confirmation and auto-logon offer (default Yes) |
| `Show-AppSummary` | Confirmation summary before account creation |
| `Invoke-AppStatus` | Status line during account creation |
| `Format-Table` | Post-creation verification table |

UTF-8 encoding is set explicitly on startup; the helpers are dot-sourced from `ConsoleUI.ps1` and need no external module.

## Example Session

```
===============  New Local User  ===============

--- Password ---
.env file found — press Enter to use stored password.
Password:

--- Username ---
Username [erik1]:

--- Confirm ---
New User Summary
  Username                 : erik1
  Password Never Expires   : True
  User May Not Change Pwd  : True
  Group                    : Administrators
  Computer                 : WORKSTATION01
Create this user? [Y/n]: y

Creating local user...

--- Verification ---

Name  Enabled PasswordNeverExpires UserMayNotChangePassword Member of Administrators
----  ------- -------------------- ------------------------ ------------------------
erik1 True    True                 True                     Yes

Log on as 'erik1' now? [Y/n]: n
```

## Post-Logon Migration Script

`src/Pwsh-NewLocalUser/Invoke-ProfileMigrationPostLogon.ps1`:

- auto-elevates if not already elevated
- grants the new local user modify access to matched source paths (via `icacls`)
- copies matched files into the same relative subfolders in the new profile
- renames each migrated file using the taxonomy-style shape `PreviousUserName - Source Folder - Existing Name - CreatedDate.ext`
  - dates already present in the existing filename, including `YYYYMMDD`, are stripped before the file-created date is appended
  - source folders are condensed for naming, e.g. `Documents\ShareX\Screenshots\2025-11` becomes `ShareX - Screenshots`
  - if a destination filename already exists, a numeric suffix is added after the date, e.g. `2026-05-26 1`
- maintains `Documents\OSM_ProfileMigrationLog.csv` in the new profile with `SourceFilePath`, `DestinationFilePath`, and `DateMoved`
- writes activity logs (default: `C:\ProgramData\OSM\logs\profile-migration-*.log`)
- displays migration results to the user
- prompts whether to remove the previous local user account from the workstation
- if the previous account is removed, prompts whether to also delete its profile directory (`C:\Users\<old>`) and `HKLM\...\ProfileList\<SID>` registry entry. Cleanup uses `Win32_UserProfile` via CIM when present (handles junction points and registry in one call) and falls back to `Remove-Item -Recurse` plus orphan registry-key cleanup when no `Win32_UserProfile` record exists.

Useful debug/testing parameters include:

- `-ConfigPath`
- `-PreviousUserProfilePath`
- `-NewUserProfilePath`
- `-LogPath`
- `-SkipRemovalPrompt`
- `-NonInteractive`
- `-WhatIf`

## Change Log

### 2026-03-03 — Initial release

- Created script with full interactive UI
- Supports .env password pre-configuration
- Auto-logon offer after successful account creation

### 2026-05-21 — Profile migration after first logon

- Added configurable profile migration rules (`ProfileMigrationPatterns.json`)
- Added pre-auto-logon detection/prompt for matching files
- Added RunOnce registration for post-logon migration
- Added `Invoke-ProfileMigrationPostLogon.ps1` with logging, ACL grant, copy, and optional previous-user removal prompt

### 2026-05-25 — Optional previous-profile-directory cleanup

- Post-logon script: after the previous local user is removed, a follow-up prompt offers to delete `C:\Users\<old>` and its `ProfileList\<SID>` registry entry
- Uses `Win32_UserProfile` via CIM when available (atomic registry+filesystem cleanup), with `Remove-Item` fallback for orphan profile directories

### 2026-05-28 — Remove PwshSpectreConsole

- Replaced all PwshSpectreConsole UI with native ConsoleUI helpers (no external module)
- Installer no longer installs PwshSpectreConsole from the PowerShell Gallery
