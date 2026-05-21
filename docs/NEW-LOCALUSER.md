# New-LocalUser.ps1

A PowerShell utility that creates a new numbered local administrator account on the current machine. It derives a base name from the running user, finds the next available numbered username, prompts interactively for credentials, creates the account, and optionally configures a one-time auto-logon before logging off.

## Prerequisites

- **Windows PowerShell 5.1+**
- **Administrator elevation** (the script will refuse to run without it)
- **PwshSpectreConsole module v2.3.0+** — provides the interactive UI
- **Microsoft.PowerShell.LocalAccounts module** — built into Windows; no installation required

### Installing PwshSpectreConsole

```powershell
Install-Module PwshSpectreConsole -RequiredVersion 2.3.0 -Scope CurrentUser
```

## Quick Start (Recommended)

Use the auto-elevating launcher instead of invoking the script directly:

```powershell
pwsh -File scripts\Start-App.ps1
```

`Start-App.ps1` checks whether the current session is elevated. If not, it re-launches the main script via `Start-Process ... -Verb RunAs`, triggering a UAC prompt. If already elevated it calls `New-LocalUser.ps1` directly in the same session.

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
- `Downloads\*.pdf`
- `Documents\ShareX\ScreenRecordings\*.mp4` (recursive)

If matches are found, the script displays per-rule counts and prompts whether to migrate them for the new user after first sign-in.

## How It Works

The script runs in seven sequential phases:

1. **Elevation check** — calls `Test-IsElevated`; terminates immediately if not running as Administrator.

2. **Password resolution** — loads `NEW_USER_PASSWORD` from `.env` if present. Enters an interactive loop (see table above) until a valid `SecureString` password is confirmed.

3. **Username resolution** — strips trailing digits from `$env:USERNAME` to derive a base name (e.g., `erik80` → `erik`), then scans existing local accounts for names matching `^<base>\d+$` and increments the highest number by 1 (starts at 1 if none exist). Presents the suggested name via `Read-SpectreText` with a default answer. Loops if the input is blank or the name is already in use.

4. **Confirmation panel** — displays a `Format-SpectrePanel` summary showing the proposed username, fixed account properties, target group, and computer name. Prompts `Read-SpectreConfirm` — answering No aborts with no changes made.

5. **User creation** — runs inside `Invoke-SpectreCommandWithStatus` (spinner). Calls `New-LocalUser` with `PasswordNeverExpires` and `UserMayNotChangePassword` set, then `Add-LocalGroupMember -Group Administrators`. A failure in either cmdlet is fatal (`$ErrorActionPreference = 'Stop'`).

6. **Verification** — reads the account back with `Get-LocalUser` and confirms Administrators membership with `Get-LocalGroupMember`. Results are displayed in a `Format-SpectreTable`.

7. **Profile migration pre-check** — Uses `ProfileMigrationPatterns.json` to scan configured folders in the current profile. If matches are found and accepted, the script registers an `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce` entry (`OSM_ProfileMigration`) that launches `Invoke-ProfileMigrationPostLogon.ps1` with `-PreviousUserName` and `-NewUserName` (plus config path) on the first logon.

8. **Auto-logon offer** — `Read-SpectreConfirm` asks whether to log on as the new account immediately. If confirmed, five registry keys are written under `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`:

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
| PwshSpectreConsole not installed | `Import-Module` throws; script terminates |
| Blank password with no `.env` | Red Spectre message; password loop repeats |
| Password confirmation mismatch | Red Spectre message; password loop repeats |
| Blank username entered | Red Spectre message; username loop repeats |
| Username already in use | Red Spectre message; username loop repeats |
| User cancels at confirmation prompt | Yellow abort message; no account created |
| `New-LocalUser` fails | Terminating error (fatal) |
| `Add-LocalGroupMember` fails | Terminating error (fatal) |

## Spectre Console UI

The script uses PwshSpectreConsole for all interactive output:

| Element | Purpose |
|---|---|
| `Write-SpectreFigletText` | Large "New Local User" banner at startup |
| `Write-SpectreRule` | Section dividers (Password, Username, Confirm, Verification) |
| `Write-SpectreHost` | Styled status and error messages |
| `Read-SpectreText` | Username prompt with pre-filled default answer |
| `Read-SpectreConfirm` | Yes/No prompts for confirmation and auto-logon offer |
| `Format-SpectrePanel` | Confirmation summary panel before account creation |
| `Invoke-SpectreCommandWithStatus` | Spinner during account creation |
| `Format-SpectreTable` | Post-creation verification table |

UTF-8 encoding is set explicitly on startup and `$env:IgnoreSpectreEncoding = $true` suppresses the module's own encoding warning.

## Example Session

```
 _   _               _                    _   _   _
| \ | |  ___ __  __ | |      ___    ___  | | | | | |  ___   ___  _ __
|  \| | / _ \\ \/ / | |     / _ \  / __| | | | | | | / __| / _ \| '__|
| |\  ||  __/ >  <  | |___ | (_) || (__  | |_| |_| | \__ \|  __/| |
|_| \_| \___|/_/\_\ |_____| \___/  \___|  \___/\___/ |___/ \___||_|

──────────────────────────── Password ────────────────────────────
.env file found — press Enter to use stored password.
Password:

──────────────────────────── Username ────────────────────────────
Username [erik1]:

──────────────────────────── Confirm ─────────────────────────────
╭─ New User Summary ──────────────────────────────────────────╮
│ Username                 erik1                               │
│ PasswordNeverExpires     True                                │
│ UserMayNotChangePassword True                                │
│ Group                    Administrators                      │
│ Computer                 WORKSTATION01                       │
╰─────────────────────────────────────────────────────────────╯
Create this user? [y/n]: y

 Creating local user... ⣾

──────────────────────────── Verification ────────────────────────
 Name  Enabled  PasswordNeverExpires  UserMayNotChangePassword  Member of Administrators
 erik1 True     True                  True                      Yes

Log on as 'erik1' now? [y/n]: n
```

## Post-Logon Migration Script

`src/Pwsh-NewLocalUser/Invoke-ProfileMigrationPostLogon.ps1`:

- auto-elevates if not already elevated
- grants the new local user modify access to matched source paths (via `icacls`)
- copies matched files into the same relative subfolders in the new profile
- writes activity logs (default: `C:\ProgramData\OSM\logs\profile-migration-*.log`)
- displays migration results to the user
- prompts whether to remove the previous local user account from the workstation

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

- Created script with full interactive UI via PwshSpectreConsole
- Supports .env password pre-configuration
- Auto-logon offer after successful account creation

### 2026-05-21 — Profile migration after first logon

- Added configurable profile migration rules (`ProfileMigrationPatterns.json`)
- Added pre-auto-logon detection/prompt for matching files
- Added RunOnce registration for post-logon migration
- Added `Invoke-ProfileMigrationPostLogon.ps1` with logging, ACL grant, copy, and optional previous-user removal prompt
