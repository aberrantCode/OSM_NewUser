# New-LocalUser Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `src/Pwsh-NewLocalUser/New-LocalUser.ps1` — a PowerShell script that creates a numbered local Windows administrator account, with a Spectre Console UI, `.env`-based password management, and optional auto-logon after creation.

**Architecture:** Standalone PowerShell 5.1+ script using `Microsoft.PowerShell.LocalAccounts` (no AD/RSAT required) and `PwshSpectreConsole 2.3.0` for rich terminal output. Helper functions (`Test-IsElevated`, `Get-BaseName`, `Get-NextUsername`, `Get-EnvPassword`, `ConvertTo-PlainText`, `Invoke-Logoff`) are declared inside the script and are mockable in Pester. Pester tests mock all external calls; the script is invoked with `& $scriptPath *>$null`. Interactive prompts use `Read-SpectreText` / `Read-SpectreConfirm` for Spectre and fall back to `Read-Host` if import fails.

**Tech Stack:** PowerShell 5.1+, `Microsoft.PowerShell.LocalAccounts`, `PwshSpectreConsole 2.3.0`, Pester 5.7.1, Git hooks (bash).

---

## Reference Files

Before starting, read these to understand patterns used throughout:

- `src/PwshScript/New-OSMUser.ps1` — existing AD script (same overall structure)
- `tests/Pester/New-OSMUser.Tests.ps1` — test pattern to follow exactly
- `docs/plans/2026-03-03-new-local-user-design.md` — approved design

---

## Task 1: Infrastructure — `.gitignore`, `.env.example`, `hooks/pre-commit`

**Files:**
- Modify: `.gitignore`
- Create: `.env.example`
- Create: `hooks/pre-commit`
- Create: `src/Pwsh-NewLocalUser/` (directory only at this stage)

### Step 1: Add `.env` to `.gitignore`

Add this block at the end of `.gitignore`:

```gitignore
# Local secrets — never commit
.env
```

### Step 2: Create `.env.example`

Create `/.env.example`:

```
# Copy this file to .env and set your value.
# .env is gitignored and must NEVER be committed.
#
# NEW_USER_PASSWORD  — password assigned to every local account created by New-LocalUser.ps1
NEW_USER_PASSWORD=YourP@ssw0rd
```

### Step 3: Create `hooks/pre-commit`

Create `/hooks/pre-commit` (no file extension):

```bash
#!/usr/bin/env bash
# Blocks commits that accidentally stage the .env secrets file.
if git diff --cached --name-only | grep -q '^\.env$'; then
  echo ""
  echo "ERROR: .env is staged for commit."
  echo "       It contains secrets and must never be committed."
  echo ""
  echo "       To unstage it:  git reset HEAD .env"
  echo ""
  exit 1
fi
```

### Step 4: Make the hook executable (Git for Windows / bash)

```bash
chmod +x hooks/pre-commit
```

### Step 5: Activate the hooks directory for this repo

```bash
git config core.hooksPath ./hooks
```

### Step 6: Create the new script directory

```bash
mkdir -p src/Pwsh-NewLocalUser
```

### Step 7: Commit

```bash
git add .gitignore .env.example hooks/pre-commit
git commit -m "chore: add .env secret management and pre-commit hook"
```

---

## Task 2: Pester Test File — Write All Failing Tests First

**Files:**
- Create: `tests/Pester/New-LocalUser.Tests.ps1`

Read `tests/Pester/New-OSMUser.Tests.ps1` in full before writing this file — the invocation model,
`BeforeAll` structure, mock helper function, and `Should -Invoke -Scope Describe` pattern must be
followed exactly.

### Step 1: Create the test file

Create `tests/Pester/New-LocalUser.Tests.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for New-LocalUser.ps1.

.DESCRIPTION
    The source script:
      1. Checks for admin elevation via Test-IsElevated helper.
      2. Imports PwshSpectreConsole.
      3. Reads .env file for NEW_USER_PASSWORD.
      4. Prompts for password via Read-Host -AsSecureString.
      5. Derives base name from env:USERNAME (strips trailing digits).
      6. Queries local users via Get-LocalUser to compute next username.
      7. Prompts for username via Read-SpectreText.
      8. Validates username is not already in use.
      9. Displays summary panel via Format-SpectrePanel.
     10. Prompts for confirmation via Read-SpectreConfirm.
     11. Creates user via Invoke-SpectreCommandWithStatus wrapping New-LocalUser.
     12. Adds to Administrators via Add-LocalGroupMember.
     13. Verifies creation via Get-LocalUser + Get-LocalGroupMember.
     14. Offers auto-logon prompt via Read-SpectreConfirm.
     15. Writes registry keys via Set-ItemProperty and calls Invoke-Logoff.

    Invocation model:
      - `& $script:ScriptPath *>$null` runs the SUT.
      - The script uses `throw` (not `exit`) for all fatal error paths.
      - For throw paths the SUT is wrapped in try/catch and $script:thrownError captured.
      - SUT invoked ONCE per Describe in BeforeAll; It blocks assert only.
      - Should -Invoke uses -Scope Describe throughout.

    Scenarios covered:
      1.  BaseName derived from env:USERNAME (strips trailing digits: 'erik7' -> 'erik').
      2.  .env file present — password loaded, blank Read-Host accepted.
      3.  No .env file — user enters password; loops once on blank, succeeds second call.
      4.  Password confirm mismatch — Read-Host called again until match.
      5.  Username already in use — Read-SpectreText called again with valid name.
      6.  User aborts at creation confirmation — New-LocalUser NOT called.
      7.  Happy path — all steps succeed, user declines auto-logon.
      8.  Happy path with auto-logon — registry keys written, Invoke-Logoff called.
      9.  Add-LocalGroupMember fails — FATAL: throws after red error message.
     10.  New-LocalUser throws — FATAL: re-throws.
     11.  Not elevated — throws with elevation message.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\Pwsh-NewLocalUser\New-LocalUser.ps1'

    # ── Shared temp .env helpers ──────────────────────────────────────────────
    function script:New-TempEnvFile {
        param([string]$Password = 'EnvP@ssw0rd')
        $script:TempEnvPath = Join-Path $TestDrive '.env'
        Set-Content -Path $script:TempEnvPath -Value "NEW_USER_PASSWORD=$Password"
        return $script:TempEnvPath
    }

    # ── Stub SecureString factory (PS 5.1 compat) ─────────────────────────────
    function script:New-SecureStringStub {
        param([string]$PlainText = 'TestP@ss1')
        $ss = [System.Security.SecureString]::new()
        foreach ($c in $PlainText.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()
        return $ss
    }

    # ── Common mocks applied in every Describe ────────────────────────────────
    function script:Set-CommonLocalUserMocks {
        param(
            [string]$ExpectedUsername  = 'testuser1',
            [string]$EnvFilePath       = '',
            [switch]$ConfirmCreate     = $true,
            [switch]$ConfirmLogon      = $false
        )

        # Elevation
        Mock Test-IsElevated { $true }

        # Spectre import (no-op — module already loaded in test session)
        Mock Import-Module { }

        # Spectre output — suppress all display
        Mock Write-SpectreFigletText  { }
        Mock Write-SpectreRule        { }
        Mock Write-SpectreHost        { }
        Mock Format-SpectrePanel      { }
        Mock Format-SpectreTable      { $Input }  # pass through pipeline for chaining
        Mock Out-SpectreHost          { }

        # Spectre spinner — must actually run its Task scriptblock
        Mock Invoke-SpectreCommandWithStatus {
            param($Title, $Task, $Spinner, $Color, $SpinnerStyle)
            & $Task
        }

        # Spectre prompts
        Mock Read-SpectreText    { $DefaultValue }   # accept default username
        Mock Read-SpectreConfirm {
            param($Question)
            if ($Question -match 'Log on') { return $ConfirmLogon.IsPresent }
            return $ConfirmCreate.IsPresent
        }

        # .env path resolution  — override so script finds our temp file
        Mock Get-EnvFilePath { return $EnvFilePath }

        # Password — Read-Host -AsSecureString returns a matching pair by default
        $ss = script:New-SecureStringStub
        Mock Read-Host { return $ss }

        # Local user cmdlets
        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                # Identity lookup after creation
                if ($Name -eq $ExpectedUsername) {
                    return [PSCustomObject]@{
                        Name               = $ExpectedUsername
                        Enabled            = $true
                        PasswordNeverExpires = $true
                        UserMayNotChangePassword = $true
                    }
                }
                # Unknown user — simulate not found
                throw "No local user '$Name' was found."
            }
            # List call for numbering
            return @()
        }

        Mock New-LocalUser        { }
        Mock Add-LocalGroupMember { }
        Mock Get-LocalGroupMember {
            @([PSCustomObject]@{ Name = $ExpectedUsername; ObjectClass = 'User' })
        }

        # Registry + logoff
        Mock Set-ItemProperty { }
        Mock Invoke-Logoff    { }
    }
}

# ── Scenario 1: BaseName derived from env:USERNAME ───────────────────────────

Describe 'BaseName derived from env:USERNAME by stripping trailing digits' {

    BeforeAll {
        $script:savedUsername = $env:USERNAME
        $env:USERNAME = 'erik7'

        Set-CommonLocalUserMocks -ExpectedUsername 'erik1'

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                if ($Name -eq 'erik1') {
                    return [PSCustomObject]@{
                        Name = 'erik1'; Enabled = $true
                        PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                    }
                }
                throw "No local user '$Name' was found."
            }
            return @()  # no existing numbered accounts
        }

        & $script:ScriptPath *>$null
    }

    AfterAll { $env:USERNAME = $script:savedUsername }

    It 'calls New-LocalUser with the username derived from env:USERNAME (erik1)' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Name -eq 'erik1'
        }
    }

    It 'calls Test-IsElevated to check for admin rights' {
        Should -Invoke Test-IsElevated -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 2: .env file present — password loaded, blank accepted ───────────

Describe '.env file present — blank Read-Host response uses env password' {

    BeforeAll {
        $envPath = script:New-TempEnvFile -Password 'EnvSecret1!'
        Set-CommonLocalUserMocks -EnvFilePath $envPath

        # Blank SecureString simulates user pressing Enter
        Mock Read-Host { [System.Security.SecureString]::new() }

        & $script:ScriptPath *>$null
    }

    It 'calls New-LocalUser (password sourced from .env, not prompt)' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Read-Host exactly once (no confirm needed when using .env value)' {
        Should -Invoke Read-Host -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 3: No .env file — blank loops until password entered ─────────────

Describe 'No .env file — blank password prompt loops until value entered' {

    BeforeAll {
        Set-CommonLocalUserMocks -EnvFilePath ''  # no .env

        $script:readHostCount = 0
        $blank  = [System.Security.SecureString]::new()
        $filled = script:New-SecureStringStub 'NewP@ss1'

        Mock Read-Host {
            $script:readHostCount++
            # first call blank (no .env, no value) → must re-prompt
            # second call returns value (password) → accepted
            # third call returns same value (confirm) → matches
            if ($script:readHostCount -le 1) { return $blank }
            return $filled
        }

        & $script:ScriptPath *>$null
    }

    It 'calls New-LocalUser after user eventually provides a password' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Read-Host at least 3 times (blank loop + password + confirm)' {
        $script:readHostCount | Should -BeGreaterOrEqual 3
    }
}

# ── Scenario 4: Password confirm mismatch — re-prompts ───────────────────────

Describe 'Password confirm mismatch causes re-prompt until passwords match' {

    BeforeAll {
        Set-CommonLocalUserMocks -EnvFilePath ''

        $script:readHostCount = 0
        $pass1   = script:New-SecureStringStub 'GoodP@ss1'
        $wrong   = script:New-SecureStringStub 'WrongP@ss!'
        $pass2   = script:New-SecureStringStub 'GoodP@ss1'
        $confirm = script:New-SecureStringStub 'GoodP@ss1'

        # Sequence: password→mismatch-confirm→password-again→matching-confirm
        Mock Read-Host {
            $script:readHostCount++
            switch ($script:readHostCount) {
                1 { return $pass1   }   # first attempt
                2 { return $wrong   }   # confirm mismatch
                3 { return $pass2   }   # retry
                4 { return $confirm }   # matching confirm
                default { return $confirm }
            }
        }

        & $script:ScriptPath *>$null
    }

    It 'eventually calls New-LocalUser after mismatch is resolved' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Read-Host at least 4 times due to mismatch loop' {
        $script:readHostCount | Should -BeGreaterOrEqual 4
    }
}

# ── Scenario 5: Username already in use — re-prompted ────────────────────────

Describe 'Username already in use causes Read-SpectreText to be called again' {

    BeforeAll {
        Set-CommonLocalUserMocks -ExpectedUsername 'freeuser1'

        $script:spectreTextCount = 0
        Mock Read-SpectreText {
            $script:spectreTextCount++
            if ($script:spectreTextCount -eq 1) { return 'inuseuser' }
            return 'freeuser1'
        }

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                if ($Name -eq 'inuseuser') {
                    return [PSCustomObject]@{ Name = 'inuseuser'; Enabled = $true }
                }
                if ($Name -eq 'freeuser1') {
                    return [PSCustomObject]@{
                        Name = 'freeuser1'; Enabled = $true
                        PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                    }
                }
                throw "No local user '$Name' was found."
            }
            return @()
        }

        & $script:ScriptPath *>$null
    }

    It 'calls Read-SpectreText twice — once for in-use name, once for valid name' {
        $script:spectreTextCount | Should -Be 2
    }

    It 'calls New-LocalUser with the valid (second) username' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Name -eq 'freeuser1'
        }
    }
}

# ── Scenario 6: User aborts at confirmation ───────────────────────────────────

Describe 'User declines confirmation — New-LocalUser is NOT called' {

    BeforeAll {
        Set-CommonLocalUserMocks -ConfirmCreate:$false

        & $script:ScriptPath *>$null
    }

    It 'does NOT call New-LocalUser when user declines' {
        Should -Invoke New-LocalUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Add-LocalGroupMember when creation is aborted' {
        Should -Invoke Add-LocalGroupMember -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ItemProperty when creation is aborted' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 7: Happy path — all steps, no auto-logon ────────────────────────

Describe 'Happy path — all steps succeed, user declines auto-logon' {

    BeforeAll {
        Set-CommonLocalUserMocks -ExpectedUsername 'newadm1' -ConfirmCreate:$true -ConfirmLogon:$false

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                if ($Name -eq 'newadm1') {
                    return [PSCustomObject]@{
                        Name = 'newadm1'; Enabled = $true
                        PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                    }
                }
                throw "No local user '$Name' was found."
            }
            return @()
        }

        & $script:ScriptPath *>$null
    }

    It 'calls Test-IsElevated' {
        Should -Invoke Test-IsElevated -Times 1 -Exactly -Scope Describe
    }

    It 'calls New-LocalUser with PasswordNeverExpires and UserMayNotChangePassword' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Name -eq 'newadm1' -and
            $PasswordNeverExpires -eq $true -and
            $UserMayNotChangePassword -eq $true
        }
    }

    It 'calls Add-LocalGroupMember for the Administrators group' {
        Should -Invoke Add-LocalGroupMember -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Group -eq 'Administrators' -and $Member -eq 'newadm1'
        }
    }

    It 'calls Get-LocalGroupMember to verify Administrators membership' {
        Should -Invoke Get-LocalGroupMember -Times 1 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ItemProperty (auto-logon declined)' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Invoke-Logoff (auto-logon declined)' {
        Should -Invoke Invoke-Logoff -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 8: Happy path WITH auto-logon ───────────────────────────────────

Describe 'Happy path with auto-logon — registry keys written and logoff called' {

    BeforeAll {
        $envPath = script:New-TempEnvFile -Password 'LogonP@ss1'
        Set-CommonLocalUserMocks -ExpectedUsername 'logonuser1' -EnvFilePath $envPath `
            -ConfirmCreate:$true -ConfirmLogon:$true

        Mock Read-Host { [System.Security.SecureString]::new() }  # blank → use .env

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                return [PSCustomObject]@{
                    Name = 'logonuser1'; Enabled = $true
                    PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                }
            }
            return @()
        }

        & $script:ScriptPath *>$null
    }

    It 'writes AutoAdminLogon registry value' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'AutoAdminLogon' -and $Value -eq '1'
        }
    }

    It 'writes DefaultUserName registry value' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'DefaultUserName' -and $Value -eq 'logonuser1'
        }
    }

    It 'writes DefaultDomainName registry value with computer name' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'DefaultDomainName' -and $Value -eq $env:COMPUTERNAME
        }
    }

    It 'writes AutoLogonCount registry value as 1' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'AutoLogonCount' -and $Value -eq '1'
        }
    }

    It 'calls Invoke-Logoff to end the current session' {
        Should -Invoke Invoke-Logoff -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 9: Add-LocalGroupMember fails — FATAL ───────────────────────────

Describe 'Add-LocalGroupMember failure is FATAL — script throws' {

    BeforeAll {
        Set-CommonLocalUserMocks -ExpectedUsername 'failgrp1'

        Mock Add-LocalGroupMember { throw 'Access denied adding to Administrators' }

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                return [PSCustomObject]@{ Name = 'failgrp1'; Enabled = $true }
            }
            return @()
        }

        $script:thrownError = $null
        try { & $script:ScriptPath *>$null } catch { $script:thrownError = $_.Exception.Message }
    }

    It 'throws when Add-LocalGroupMember fails' {
        $script:thrownError | Should -Not -BeNullOrEmpty
    }

    It 'calls New-LocalUser before the fatal group-add failure' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ItemProperty after a fatal group-add failure' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 10: New-LocalUser throws — FATAL ─────────────────────────────────

Describe 'New-LocalUser failure is FATAL — script re-throws' {

    BeforeAll {
        Set-CommonLocalUserMocks

        Mock New-LocalUser { throw [System.Exception]::new('The user account already exists') }

        $script:thrownError = $null
        try { & $script:ScriptPath *>$null } catch { $script:thrownError = $_.Exception.Message }
    }

    It 'throws when New-LocalUser fails' {
        $script:thrownError | Should -Not -BeNullOrEmpty
    }

    It 'does NOT call Add-LocalGroupMember after New-LocalUser failure' {
        Should -Invoke Add-LocalGroupMember -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ItemProperty after New-LocalUser failure' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 11: Not elevated — throws ────────────────────────────────────────

Describe 'Not elevated — throws with elevation error message' {

    BeforeAll {
        Set-CommonLocalUserMocks
        Mock Test-IsElevated { $false }

        $script:thrownError = $null
        try { & $script:ScriptPath *>$null } catch { $script:thrownError = $_.Exception.Message }
    }

    It 'throws when not running as Administrator' {
        $script:thrownError | Should -Not -BeNullOrEmpty
    }

    It 'does NOT call New-LocalUser when not elevated' {
        Should -Invoke New-LocalUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Import-Module when not elevated' {
        Should -Invoke Import-Module -Times 0 -Exactly -Scope Describe
    }
}
```

### Step 2: Run tests to verify they all fail (script doesn't exist yet)

```powershell
Invoke-Pester -Path tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed
```

Expected: All tests fail. Error should be something like:
`Cannot find path '...\src\Pwsh-NewLocalUser\New-LocalUser.ps1'`

### Step 3: Commit the test file

```bash
git add tests/Pester/New-LocalUser.Tests.ps1
git commit -m "test: add failing Pester tests for New-LocalUser.ps1 (TDD red phase)"
```

---

## Task 3: Script Scaffold — Helper Functions and Stub Main Body

**Files:**
- Create: `src/Pwsh-NewLocalUser/New-LocalUser.ps1`

This task creates the script with all helper functions fully implemented, but the main execution
body is a minimal stub. Tests that assert on specific behavior will still fail — that's expected.

### Step 1: Create `src/Pwsh-NewLocalUser/New-LocalUser.ps1`

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new numbered local administrator account on this machine.

.DESCRIPTION
    Derives a base name from the current user (strips trailing digits), finds
    the next available numbered local account, prompts for a username and
    password, then creates the account with PasswordNeverExpires and
    UserMayNotChangePassword set, and adds it to the local Administrators group.

    Password is read from a .env file (NEW_USER_PASSWORD) at the solution root,
    with an interactive prompt that falls back to that value when left blank.

    After successful creation the script optionally configures Windows
    auto-logon (one-time) and immediately logs off the current session.

.NOTES
    Requires: PowerShell 5.1+, admin elevation, PwshSpectreConsole module.
    Run via: scripts\Start-App.ps1  (auto-elevates if needed)
#>

$ErrorActionPreference = 'Stop'

# ── Elevation guard ───────────────────────────────────────────────────────────
# Declared as a function so Pester can mock it.
function Test-IsElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsElevated)) {
    Write-Host 'ERROR: This script must be run as Administrator. Use scripts\Start-App.ps1.' -ForegroundColor Red
    throw 'Script must be run as Administrator.'
}

# ── Spectre Console ───────────────────────────────────────────────────────────
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:IgnoreSpectreEncoding = $true   # we set UTF-8 above; suppress the module warning
Import-Module PwshSpectreConsole -ErrorAction Stop

# ── Helper: resolve .env file path ───────────────────────────────────────────
# Declared as a function so Pester can mock it.
function Get-EnvFilePath {
    return (Join-Path $PSScriptRoot '..\..\' '.env' | Resolve-Path -ErrorAction SilentlyContinue)
}

# ── Helper: extract NEW_USER_PASSWORD from .env ───────────────────────────────
function Get-EnvPassword {
    param([string]$EnvFilePath)
    if ([string]::IsNullOrEmpty($EnvFilePath) -or -not (Test-Path $EnvFilePath)) { return $null }
    $content = Get-Content $EnvFilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $null }
    $match = [regex]::Match($content, '(?m)^NEW_USER_PASSWORD=(.+)$')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

# ── Helper: derive base name from current username ────────────────────────────
function Get-BaseName {
    return $env:USERNAME -replace '\d+$', ''
}

# ── Helper: compute the next available username ───────────────────────────────
function Get-NextUsername {
    param([string]$BaseName)
    $existing = Get-LocalUser | Select-Object -ExpandProperty Name
    $escaped  = [regex]::Escape($BaseName)
    $pattern  = "^$escaped(\d+)$"
    $numbers  = $existing |
        Where-Object { $_ -imatch $pattern } |
        ForEach-Object { [int]([regex]::Match($_, $pattern).Groups[1].Value) }
    $next = if ($numbers) { ($numbers | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    return "$BaseName$next"
}

# ── Helper: SecureString → plain text (PS 5.1 compatible) ────────────────────
function ConvertTo-PlainText {
    param([System.Security.SecureString]$SecureString)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ── Helper: logoff wrapper (mockable in Pester) ───────────────────────────────
function Invoke-Logoff { logoff }

# ── Main execution ────────────────────────────────────────────────────────────
Write-SpectreFigletText -Text 'New Local User' -Color 'Cyan'

# (Phases 2–7 implemented in subsequent tasks)
throw 'Not yet implemented'
```

### Step 2: Run the tests — only Scenario 11 (not elevated) should pass now

```powershell
Invoke-Pester -Path tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed
```

Expected: Scenario 11 passes. All others fail on the stub `throw 'Not yet implemented'`.

### Step 3: Commit scaffold

```bash
git add src/Pwsh-NewLocalUser/New-LocalUser.ps1
git commit -m "feat: scaffold New-LocalUser.ps1 with helpers and elevation guard"
```

---

## Task 4: Phase 2 — Password Resolution

**Files:**
- Modify: `src/Pwsh-NewLocalUser/New-LocalUser.ps1` (replace the `throw 'Not yet implemented'` stub with Phase 2 logic)

### Step 1: Replace the stub with Phase 2 implementation

Remove the line `throw 'Not yet implemented'` and add this block in its place:

```powershell
# ── Phase 2: Password resolution ─────────────────────────────────────────────
Write-SpectreRule -Title 'Password' -Color 'Grey'

$envFilePath = Get-EnvFilePath
$envPlain    = Get-EnvPassword -EnvFilePath $envFilePath

if ($envPlain) {
    Write-SpectreHost '[grey].env file found — press [bold]Enter[/] to use stored password.[/]'
} else {
    Write-SpectreHost '[yellow]Warning: No .env file found. You must enter a password.[/]'
    Write-SpectreHost '[grey]  (Press Ctrl+C at any time to cancel.)[/]'
}

$securePassword = $null

while ($null -eq $securePassword) {
    Write-SpectreHost 'Password: ' -NoNewline
    $inputSecure = Read-Host -AsSecureString

    $inputPlain = ConvertTo-PlainText -SecureString $inputSecure

    if ([string]::IsNullOrEmpty($inputPlain)) {
        if ($envPlain) {
            # blank + .env present → use .env value
            $securePassword = ConvertTo-SecureString -String $envPlain -AsPlainText -Force
        } else {
            Write-SpectreHost '[red]Password cannot be blank when no .env file is present.[/]'
            # loop continues
        }
    } else {
        # Non-blank: require confirmation
        Write-SpectreHost 'Confirm password: ' -NoNewline
        $confirmSecure = Read-Host -AsSecureString
        $confirmPlain  = ConvertTo-PlainText -SecureString $confirmSecure

        if ($inputPlain -ne $confirmPlain) {
            Write-SpectreHost '[red]Passwords do not match. Please try again.[/]'
            # loop continues
        } else {
            $securePassword = $inputSecure
        }
    }
}

# (Phase 3 continues below — implemented in Task 5)
throw 'Phase 3 not yet implemented'
```

### Step 2: Run tests — Scenarios 2, 3, 4 should now pass

```powershell
Invoke-Pester -Path tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed
```

Expected passing: Scenarios 2, 3, 4, 11.
Still failing: Scenarios 1, 5, 6, 7, 8, 9, 10 (hit the Phase 3 stub throw).

### Step 3: Commit

```bash
git add src/Pwsh-NewLocalUser/New-LocalUser.ps1
git commit -m "feat: implement password resolution phase in New-LocalUser.ps1"
```

---

## Task 5: Phase 3 — Username Resolution

**Files:**
- Modify: `src/Pwsh-NewLocalUser/New-LocalUser.ps1`

### Step 1: Replace the Phase 3 stub with username resolution

Remove `throw 'Phase 3 not yet implemented'` and add:

```powershell
# ── Phase 3: Username resolution ─────────────────────────────────────────────
Write-SpectreRule -Title 'Username' -Color 'Grey'

$baseName  = Get-BaseName
$suggested = Get-NextUsername -BaseName $baseName

$username = $null

while ($null -eq $username) {
    $input = Read-SpectreText -Question 'Username' -DefaultValue $suggested

    $trimmed = $input.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Write-SpectreHost '[red]Username cannot be blank.[/]'
        continue
    }

    # Check whether the name is already taken
    $existing = try { Get-LocalUser -Name $trimmed -ErrorAction Stop } catch { $null }
    if ($null -ne $existing) {
        Write-SpectreHost "[red]'$trimmed' is already in use. Choose a different username.[/]"
        continue
    }

    $username = $trimmed
}

# (Phase 4 continues below — implemented in Task 6)
throw 'Phase 4 not yet implemented'
```

### Step 2: Run tests — Scenarios 1 and 5 should now pass

```powershell
Invoke-Pester -Path tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed
```

Expected passing: Scenarios 1, 2, 3, 4, 5, 11.

### Step 3: Commit

```bash
git add src/Pwsh-NewLocalUser/New-LocalUser.ps1
git commit -m "feat: implement username resolution phase in New-LocalUser.ps1"
```

---

## Task 6: Phase 4 + 5 — Confirmation and User Creation

**Files:**
- Modify: `src/Pwsh-NewLocalUser/New-LocalUser.ps1`

### Step 1: Replace the Phase 4 stub

Remove `throw 'Phase 4 not yet implemented'` and add:

```powershell
# ── Phase 4: Confirmation ─────────────────────────────────────────────────────
Write-SpectreRule -Title 'Summary' -Color 'Cyan'

$summaryRows = @(
    [PSCustomObject]@{ Property = 'Username';              Value = $username }
    [PSCustomObject]@{ Property = 'Computer';              Value = $env:COMPUTERNAME }
    [PSCustomObject]@{ Property = 'Group';                 Value = 'Administrators' }
    [PSCustomObject]@{ Property = 'PasswordNeverExpires';  Value = 'True' }
    [PSCustomObject]@{ Property = 'UserMayNotChangePassword'; Value = 'True' }
    [PSCustomObject]@{ Property = 'ChangePasswordAtLogon'; Value = 'False' }
)

$summaryRows | Format-SpectreTable -Color 'Cyan' | Format-SpectrePanel -Header 'New Local User' -Color 'Cyan'

if (-not (Read-SpectreConfirm -Question "Create local user '$username'?")) {
    Write-SpectreHost '[yellow]Aborted. No changes were made.[/]'
    return
}

# ── Phase 5: Creation ─────────────────────────────────────────────────────────
Write-SpectreRule -Title 'Creating' -Color 'Grey'

Invoke-SpectreCommandWithStatus -Title "Creating local user '$username'..." -Color 'Blue' -Task {
    New-LocalUser `
        -Name                 $username `
        -Password             $securePassword `
        -PasswordNeverExpires:$true `
        -UserMayNotChangePassword:$true
}

# Group add — FATAL if it fails
try {
    Add-LocalGroupMember -Group 'Administrators' -Member $username
} catch {
    Write-SpectreHost "[red]ERROR: User '$username' was created but could NOT be added to Administrators.[/]"
    Write-SpectreHost "[red]       Add the user to Administrators manually before use.[/]"
    Write-SpectreHost "[red]       Details: $_[/]"
    throw
}

# (Phase 6 continues below — implemented in Task 7)
throw 'Phase 6 not yet implemented'
```

### Step 2: Run tests — Scenarios 6, 9, 10 should now pass

```powershell
Invoke-Pester -Path tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed
```

Expected passing: Scenarios 1, 2, 3, 4, 5, 6, 9, 10, 11.

### Step 3: Commit

```bash
git add src/Pwsh-NewLocalUser/New-LocalUser.ps1
git commit -m "feat: implement confirmation and user creation phases in New-LocalUser.ps1"
```

---

## Task 7: Phase 6 + 7 — Verification and Auto-Logon

**Files:**
- Modify: `src/Pwsh-NewLocalUser/New-LocalUser.ps1`

### Step 1: Replace the Phase 6 stub

Remove `throw 'Phase 6 not yet implemented'` and add:

```powershell
# ── Phase 6: Verification ─────────────────────────────────────────────────────
Write-SpectreRule -Title 'Verification' -Color 'Green'

$created  = Get-LocalUser -Name $username
$members  = Get-LocalGroupMember -Group 'Administrators'
$isMember = $members | Where-Object { $_.Name -imatch "(^|\\)$([regex]::Escape($username))$" }

$verifyRows = @(
    [PSCustomObject]@{ Property = 'Name';                    Value = $created.Name }
    [PSCustomObject]@{ Property = 'Enabled';                 Value = $created.Enabled.ToString() }
    [PSCustomObject]@{ Property = 'PasswordNeverExpires';    Value = $created.PasswordNeverExpires.ToString() }
    [PSCustomObject]@{ Property = 'UserMayNotChangePassword'; Value = $created.UserMayNotChangePassword.ToString() }
    [PSCustomObject]@{ Property = 'Administrators member';   Value = if ($isMember) { 'Yes' } else { 'No (verify manually)' } }
)

$verifyRows | Format-SpectreTable -Color 'Green' | Format-SpectrePanel -Header 'Account Created' -Color 'Green'

# ── Phase 7: Auto-logon offer ─────────────────────────────────────────────────
if (-not (Read-SpectreConfirm -Question "Log on as '$username' now?")) {
    Write-SpectreHost '[green]Done. You can log on as the new user at any time.[/]'
    return
}

# Write one-time auto-logon registry keys
$plainPassword  = ConvertTo-PlainText -SecureString $securePassword
$winlogonPath   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

Set-ItemProperty -Path $winlogonPath -Name 'AutoAdminLogon'    -Value '1'
Set-ItemProperty -Path $winlogonPath -Name 'DefaultUserName'   -Value $username
Set-ItemProperty -Path $winlogonPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME
Set-ItemProperty -Path $winlogonPath -Name 'DefaultPassword'   -Value $plainPassword
Set-ItemProperty -Path $winlogonPath -Name 'AutoLogonCount'    -Value '1'

# Zero out in-memory plain text immediately
$plainPassword = $null

Write-SpectreHost '[yellow]Auto-logon configured (one-time). Logging off now...[/]'
Invoke-Logoff
```

### Step 2: Run the full test suite — all 11 scenarios should pass

```powershell
Invoke-Pester -Path tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed
```

Expected: **All tests pass.** If any fail, read the error message carefully:
- Mock parameter name mismatches → fix `ParameterFilter` expressions
- Scoping issues in `Invoke-SpectreCommandWithStatus` mock → ensure `$Task` is the correct param name
- `Get-LocalUser` mock call count issues → check the mock conditions

### Step 3: Commit

```bash
git add src/Pwsh-NewLocalUser/New-LocalUser.ps1
git commit -m "feat: implement verification and auto-logon phases in New-LocalUser.ps1"
```

---

## Task 8: `scripts/Start-App.ps1` Launcher

**Files:**
- Create: `scripts/Start-App.ps1`

### Step 1: Create the launcher

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Launches New-LocalUser.ps1, auto-elevating to Administrator if needed.

.DESCRIPTION
    Detects whether the current session is elevated. If not, re-launches
    itself as Administrator via Start-Process -Verb RunAs (triggers a UAC
    prompt). Once elevated, runs New-LocalUser.ps1 from its canonical
    location relative to this file.
#>

$scriptRoot   = $PSScriptRoot
$targetScript = Join-Path $scriptRoot '..\src\Pwsh-NewLocalUser\New-LocalUser.ps1'
$targetScript = (Resolve-Path $targetScript).Path

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$targetScript`""
    Start-Process pwsh -ArgumentList $args -Verb RunAs
    exit
}

& $targetScript
```

### Step 2: Commit

```bash
git add scripts/Start-App.ps1
git commit -m "feat: add Start-App.ps1 launcher with auto-elevation"
```

---

## Task 9: `docs/NEW-LOCALUSER.md` Reference Documentation

**Files:**
- Create: `docs/NEW-LOCALUSER.md`

### Step 1: Create the documentation file

```markdown
# New-LocalUser.ps1

A PowerShell utility for creating numbered local administrator accounts on a
Windows machine. It auto-increments based on existing local accounts with the
same base name — running it twice produces sequential usernames
(e.g., `erik3`, `erik4`).

## Prerequisites

- **Windows PowerShell 5.1+** or PowerShell 7+
- **Administrator elevation** (the launcher `scripts/Start-App.ps1` handles this automatically)
- **PwshSpectreConsole** module installed: `Install-Module PwshSpectreConsole`
- A `.env` file at the repository root (see [Password Setup](#password-setup))

## Quick Start

```powershell
# From the repository root (auto-elevates):
.\scripts\Start-App.ps1
```

## Password Setup

The script reads the new user's password from a `.env` file in the repository root.

1. Copy `.env.example` to `.env`:
   ```
   cp .env.example .env
   ```
2. Edit `.env` and set your value:
   ```
   NEW_USER_PASSWORD=YourSecureP@ssw0rd
   ```
3. The `.env` file is gitignored and must **never** be committed.

At runtime the script will:
- Load the password silently if `.env` is present (press Enter to accept)
- Prompt you to type a password (with confirmation) if `.env` is missing
- Loop until a non-empty password is entered — press Ctrl+C to cancel

## Git Hook Setup (One-Time)

Activate the pre-commit hook that prevents `.env` from being accidentally staged:

```bash
git config core.hooksPath ./hooks
```

This is a one-time setup per clone. The hook is committed to `hooks/pre-commit`.

## How It Works

The script follows this sequence:

1. **Elevation check** — Throws immediately if not running as Administrator.
2. **Import PwshSpectreConsole** — Rich terminal UI.
3. **Load .env password** — Reads `NEW_USER_PASSWORD` from `.env` if present.
4. **Password prompt** — Interactive `Read-Host -AsSecureString`. Blank = use .env value.
   Requires confirmation when a new value is typed.
5. **Derive base name** — Strips trailing digits from `$env:USERNAME`
   (e.g., `erik3` → `erik`).
6. **Compute next username** — Queries all local users, regex-filters
   `^{base}\d+$`, finds the highest number, suggests `base + (max + 1)`.
   If none exist, suggests `base1`.
7. **Username prompt** — `Read-SpectreText` with the suggested default. Loops
   if the entered name is already taken.
8. **Confirmation summary** — Displays a table of all properties and prompts Y/N.
9. **Create user** — `New-LocalUser` with `PasswordNeverExpires` and
   `UserMayNotChangePassword`, shown with a spinner.
10. **Add to Administrators** — `Add-LocalGroupMember`. Failure here is **fatal**
    (user was created; error message explains manual remediation).
11. **Verify** — Reads the account back and displays a green verification table.
12. **Auto-logon offer** — Optional: configures Windows one-time auto-logon and
    calls `logoff` to end the current session.

## Account Properties

Every account created has these properties:

| Property | Value |
|---|---|
| Name | `<base><N>` (e.g., `erik4`) |
| Enabled | `True` |
| PasswordNeverExpires | `True` |
| UserMayNotChangePassword | `True` |
| ChangePasswordAtLogon | `False` (not prompted) |
| Group membership | `Administrators` (local) |

## Auto-Logon Behavior

When you confirm "Log on as X now?", the script:

1. Writes one-time auto-logon keys to
   `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`:
   - `AutoAdminLogon = "1"`
   - `DefaultUserName = <username>`
   - `DefaultDomainName = <COMPUTERNAME>`
   - `DefaultPassword = <password>` *(cleared from memory immediately after write)*
   - `AutoLogonCount = "1"` *(Windows deletes credentials after first use)*
2. Runs `logoff` — current session ends immediately.

On the next sign-in screen, Windows will automatically sign in as the new user once,
then clear the credentials.

## Error Handling

| Scenario | Behaviour |
|---|---|
| Not elevated | Red error, throws (use `Start-App.ps1`) |
| PwshSpectreConsole not installed | Red error from `Import-Module -ErrorAction Stop` |
| `.env` missing | Yellow warning, continues to prompt |
| Blank password + no `.env` | Red error, re-prompts (loop) |
| Password confirm mismatch | Red error, re-prompts (loop) |
| Username already in use | Red error, re-prompts (loop) |
| User declines confirmation | Yellow "Aborted.", exits |
| `New-LocalUser` fails | Red error, rethrows (fatal) |
| `Add-LocalGroupMember` fails | Red error noting user was created, rethrows (fatal) |

## Files

| File | Purpose |
|---|---|
| `src/Pwsh-NewLocalUser/New-LocalUser.ps1` | Main script |
| `scripts/Start-App.ps1` | Auto-elevating launcher |
| `.env` | Local secrets (gitignored) |
| `.env.example` | Template — copy to `.env` |
| `hooks/pre-commit` | Blocks staged `.env` commits |
| `tests/Pester/New-LocalUser.Tests.ps1` | Pester 5 test suite |

## Running Tests

```powershell
Invoke-Pester -Path tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed
```

## Change Log

| Version | Date | Change |
|---|---|---|
| 1.0.0 | 2026-03-03 | Initial release |
```

### Step 2: Commit

```bash
git add docs/NEW-LOCALUSER.md
git commit -m "docs: add NEW-LOCALUSER.md reference documentation"
```

---

## Task 10: Root `README.md`

**Files:**
- Create: `README.md`

### Step 1: Create the root README

```markdown
# OSM New User Tools

A collection of tools for creating and provisioning numbered administrator accounts
in on-site managed (OSM) Windows environments.

## Components

### New-LocalUser (PowerShell — local accounts)

Creates a numbered local administrator account on this machine.
Uses `Microsoft.PowerShell.LocalAccounts` — no Active Directory or RSAT required.

**Quick start:**
```powershell
.\scripts\Start-App.ps1   # auto-elevates via UAC
```

**Documentation:** [`docs/NEW-LOCALUSER.md`](docs/NEW-LOCALUSER.md)

---

### New-OSMUser (PowerShell — Active Directory)

Creates a numbered Active Directory administrator account using RSAT.

**Location:** `src/PwshScript/New-OSMUser.ps1`

**Documentation:** [`src/PwshScript/README.md`](src/PwshScript/README.md)

---

### OsmUserWeb (ASP.NET Core web server — Active Directory)

A self-hosted HTTPS web UI for creating numbered AD administrator accounts.
Runs as a Windows Service (`svc-osmweb`).

**Documentation:** [`src/DotNet-DomainWebServer/README.md`](src/DotNet-DomainWebServer/README.md)
| [`src/DotNet-DomainWebServer/INSTALL.md`](src/DotNet-DomainWebServer/INSTALL.md)

---

## Repository Structure

```
src/
  Pwsh-NewLocalUser/     PowerShell script — local account creation
  PwshScript/            PowerShell script — AD account creation
  DotNet-DomainWebServer/ ASP.NET Core web server — AD account creation
scripts/
  Start-App.ps1          Launcher for New-LocalUser.ps1 (auto-elevates)
tests/
  Pester/                Pester 5 test suite for all PowerShell scripts
  OsmUserWeb.Tests/      xUnit integration tests for the web server
docs/
  NEW-LOCALUSER.md       New-LocalUser reference documentation
  plans/                 Design and implementation plan documents
hooks/
  pre-commit             Blocks accidental .env commits
```

## First-Time Setup

```bash
# Activate the pre-commit hook (one time per clone):
git config core.hooksPath ./hooks

# Create your local .env file:
cp .env.example .env
# Edit .env and set NEW_USER_PASSWORD=<your password>
```

## Running Tests

```powershell
# All PowerShell tests:
Invoke-Pester -Path tests/Pester/ -Output Detailed

# All .NET tests:
dotnet test src/DotNet-DomainWebServer/
```
```

### Step 2: Commit

```bash
git add README.md
git commit -m "docs: add root README.md with project overview"
```

---

## Task 11: Final Verification

### Step 1: Run the full Pester suite to confirm nothing regressed

```powershell
Invoke-Pester -Path tests/Pester/ -Output Detailed
```

Expected: All tests pass (≥217 existing + the new New-LocalUser tests).

### Step 2: Verify all files are present

```bash
ls src/Pwsh-NewLocalUser/
ls scripts/
ls hooks/
ls docs/
```

Expected:
- `src/Pwsh-NewLocalUser/New-LocalUser.ps1` ✓
- `scripts/Start-App.ps1` ✓
- `hooks/pre-commit` ✓
- `.env.example` ✓
- `docs/NEW-LOCALUSER.md` ✓
- `README.md` ✓

### Step 3: Verify .gitignore blocks .env

```bash
echo "NEW_USER_PASSWORD=test" > .env
git status
```

Expected: `.env` does NOT appear in untracked files.

### Step 4: Test pre-commit hook blocks staged .env

```bash
git add -f .env   # force-stage (for testing only)
git commit -m "test"
```

Expected: Commit rejected with `ERROR: .env is staged for commit.`

```bash
git reset HEAD .env
rm .env
```

### Step 5: Final commit if anything was missed

```bash
git status
# Only commit if there are actual untracked changes
git add <any missed files>
git commit -m "chore: final cleanup for New-LocalUser feature"
```
