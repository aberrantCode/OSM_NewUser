# New-LocalUser — Design Document

**Date:** 2026-03-03
**Status:** Approved

---

## Goal

Add a standalone PowerShell script (`src/Pwsh-NewLocalUser/New-LocalUser.ps1`) that creates a
numbered local Windows administrator account, mirroring the account-property logic of the existing
`New-OSMUser.ps1` (AD) and `AdUserService.cs` (web server) but targeting the local machine rather
than Active Directory. A launcher (`scripts/Start-App.ps1`), supporting infrastructure
(`.env`, `.env.example`, `hooks/pre-commit`), a full reference doc (`docs/NEW-LOCALUSER.md`),
and a root `README.md` are also created.

---

## Files Created / Modified

| File | Action |
|---|---|
| `src/Pwsh-NewLocalUser/New-LocalUser.ps1` | Create — main script |
| `scripts/Start-App.ps1` | Create — auto-elevating launcher |
| `.env` | Create locally (gitignored) |
| `.env.example` | Create — committed template |
| `.gitignore` | Update — add `.env` entry |
| `hooks/pre-commit` | Create — bash hook, blocks staged `.env` |
| `docs/NEW-LOCALUSER.md` | Create — full reference documentation |
| `README.md` | Create — root project overview |

---

## Module

`Microsoft.PowerShell.LocalAccounts` (built into PowerShell 5.1+ — no RSAT / AD required).
`PwshSpectreConsole 2.3.0` (confirmed installed) for rich terminal UI.

---

## Spectre Console Mapping

| Script element | Cmdlet |
|---|---|
| Title banner | `Write-SpectreFigletText` |
| Section dividers | `Write-SpectreRule` |
| Colored status messages | `Write-SpectreHost` (`[red]`, `[green]`, `[yellow]`) |
| Summary box | `Format-SpectrePanel` + `Format-SpectreTable` |
| Username prompt | `Read-SpectreText -Question "..." -DefaultValue $suggested` |
| Y/N confirmations | `Read-SpectreConfirm` |
| Spinner during creation | `Invoke-SpectreCommandWithStatus` |
| Verification results | `Format-SpectreTable` |

Password input uses `Read-Host -AsSecureString` (no Spectre equivalent), preceded by a
`Write-SpectreHost` label.  UTF-8 encoding is set at script top to suppress the Spectre
encoding warning and enable full glyph support.

---

## Script Flow — New-LocalUser.ps1

### Phase 1 — Setup
1. Require admin elevation; exit with `Write-SpectreHost` red error if not elevated
   (launcher auto-elevates; this is a safety net).
2. Set UTF-8 console encoding; import `PwshSpectreConsole`; `$ErrorActionPreference = 'Stop'`.
3. Derive `$solutionRoot` from `"$PSScriptRoot\..\.."`.

### Phase 2 — Password Resolution
4. Look for `$solutionRoot\.env`; parse `NEW_USER_PASSWORD=<value>`.
5. If `.env` missing → yellow warning via `Write-SpectreHost`.
6. `Write-SpectreHost` password prompt label; `Read-Host -AsSecureString`.
7. Blank + `.env` present → use env value; no confirmation needed.
8. Blank + no `.env` → red error; loop back to step 6. *(Press Ctrl+C to cancel.)*
9. Non-blank → second `Read-Host -AsSecureString` confirm prompt; compare via BSTR plain-text;
   on mismatch red error + loop back to step 6.

### Phase 3 — Username Resolution
10. Derive base: `$env:USERNAME -replace '\d+$', ''`.
11. `Get-LocalUser | Select-Object -ExpandProperty Name`; regex-filter `^{base}\d+$`;
    compute `max+1` → `$suggested` (or `{base}1` if none exist).
12. `Read-SpectreText -Question "Username" -DefaultValue $suggested`
    (blank = accept default).
13. Validation loop: trim whitespace; check not empty; `Get-LocalUser -Name $trimmed
    -ErrorAction SilentlyContinue` — if found, red message + re-prompt.

### Phase 4 — Confirmation
14. `Format-SpectrePanel` containing a `Format-SpectreTable` with rows:
    Username, PasswordNeverExpires=True, UserMayNotChangePassword=True,
    Group=Administrators, Computer=`$env:COMPUTERNAME`.
15. `Read-SpectreConfirm "Create this user?"` → if No: yellow "Aborted." and exit.

### Phase 5 — Creation
16. `Invoke-SpectreCommandWithStatus "Creating local user..."` wrapping:
    - `New-LocalUser -Name $username -Password $securePassword -PasswordNeverExpires:$true -UserMayNotChangePassword:$true`
    - `Add-LocalGroupMember -Group "Administrators" -Member $username`
    - If group-add throws → `Write-SpectreHost` red error (user was created; note manual
      remediation) then rethrow (fatal).

### Phase 6 — Verification
17. `Get-LocalUser -Name $username`; `Get-LocalGroupMember -Group "Administrators"` to confirm
    membership.
18. Display `Format-SpectreTable` (green theme) with: Name, Enabled, PasswordNeverExpires,
    UserMayNotChangePassword, Member of Administrators.

### Phase 7 — Auto-Logon Offer
19. `Read-SpectreConfirm "Log on as '$username' now?"`.
20. If Yes:
    - Convert `$securePassword` to plain text via BSTR (momentary, in-memory only).
    - Write `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`:
      `AutoAdminLogon="1"`, `DefaultUserName=$username`,
      `DefaultDomainName=$env:COMPUTERNAME`, `DefaultPassword=<plain>`,
      `AutoLogonCount="1"` (Windows clears credentials after first use).
    - `Write-SpectreHost` note: *"Auto-logon configured (one-time). Logging off now..."*
    - `logoff`

---

## Launcher — scripts/Start-App.ps1

```
if not elevated:
    Start-Process pwsh -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File <script>" -Verb RunAs
else:
    & <script>
```

---

## .env Format

```
NEW_USER_PASSWORD=YourP@ssw0rd
```

`.env.example` (committed) contains the same key with a placeholder value and a comment explaining its purpose.

---

## Pre-Commit Hook — hooks/pre-commit

```bash
#!/usr/bin/env bash
if git diff --cached --name-only | grep -q '^\.env$'; then
  echo "ERROR: .env is staged for commit. It contains secrets and must not be committed."
  echo "Run: git reset HEAD .env"
  exit 1
fi
```

Activated by: `git config core.hooksPath ./hooks`

---

## .gitignore Addition

```
# Local secrets
.env
```

---

## Password Comparison (PS 5.1 Compatible)

```powershell
function ConvertTo-PlainText ([SecureString]$s) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try   { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
```

---

## Error Handling Summary

| Scenario | Behaviour |
|---|---|
| Not elevated | Red error, exit |
| `.env` missing | Yellow warning, continue |
| Blank password + no `.env` | Red error, re-prompt (loop) |
| Password confirm mismatch | Red error, re-prompt (loop) |
| Username already exists | Red error, re-prompt (loop) |
| User cancels at Y/N | Yellow "Aborted.", exit |
| `New-LocalUser` fails | Red error via Spectre, rethrow |
| `Add-LocalGroupMember` fails | Red error (user was created — note), rethrow (fatal) |
| Registry write fails | Red error, rethrow |
