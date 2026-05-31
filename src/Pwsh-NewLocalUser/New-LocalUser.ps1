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
    auto-logon (one-time) and immediately reboots the machine.

.NOTES
    Requires: PowerShell 5.1+, admin elevation.
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

# ── Console UI ───────────────────────────────────────────────────────────
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
# Guarded so the Pester suite can pre-load and mock these helpers.
if (-not (Get-Command Write-AppHost -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ConsoleUI.ps1')
}

# ── Helper: resolve .env file path ───────────────────────────────────────────
# Declared as a function so Pester can mock it.
function Get-EnvFilePath {
    $resolved = Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..\..') '.env') -ErrorAction SilentlyContinue
    if ($resolved) { return $resolved.Path }
    return $null
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
    $reOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $numbers  = $existing |
        Where-Object { [regex]::IsMatch($_, $pattern, $reOptions) } |
        ForEach-Object { [int]([regex]::Match($_, $pattern, $reOptions).Groups[1].Value) }
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

# ── Helper: reboot wrapper (mockable in Pester) ───────────────────────────────
function Invoke-Reboot { Restart-Computer -Force }

# Quote an argument for a native command line stored in a RunOnce REG_SZ value.
# RunOnce launches the value through CreateProcess (no shell), so the path passed
# to powershell.exe's -File parameter must be DOUBLE-quoted: single quotes are not
# stripped by CommandLineToArgvW and -File then rejects the literal 'path' as
# "The given path's format is not supported", silently aborting the migration.
function ConvertTo-CommandLineArgument {
    param([string]$Value)
    $safeValue = if ($null -eq $Value) { '' } else { $Value }
    return '"' + ($safeValue -replace '"', '\"') + '"'
}

function Get-ProfileMigrationRules {
    param([string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path $ConfigPath -PathType Leaf)) {
        return @()
    }

    try {
        $raw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
        $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    } catch {
        Write-AppHost "[yellow]Warning: Could not parse migration config '$ConfigPath'. Profile migration will be skipped.[/]"
        return @()
    }

    $rules = @($parsed)
    return $rules | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.RelativePath) -and
        -not [string]::IsNullOrWhiteSpace($_.Pattern)
    }
}

function Get-ProfileMigrationCandidates {
    param(
        [string]$CurrentProfilePath,
        [string]$ConfigPath
    )

    $resultsByPath = @{}
    $rules = Get-ProfileMigrationRules -ConfigPath $ConfigPath
    foreach ($rule in $rules) {
        $sourcePath = Join-Path $CurrentProfilePath $rule.RelativePath
        if (-not (Test-Path $sourcePath -PathType Container)) {
            continue
        }

        $getChildItemArgs = @{
            Path        = $sourcePath
            Filter      = $rule.Pattern
            File        = $true
            ErrorAction = 'SilentlyContinue'
        }
        if ($rule.Recurse) { $getChildItemArgs.Recurse = $true }

        $matched = @(Get-ChildItem @getChildItemArgs)
        if ($matched.Count -gt 0) {
            $key = $rule.RelativePath
            if (-not $resultsByPath.ContainsKey($key)) {
                $resultsByPath[$key] = [PSCustomObject]@{
                    RelativePath = $rule.RelativePath
                    Pattern      = New-Object System.Collections.Generic.List[string]
                    SourcePath   = $sourcePath
                    Count        = 0
                }
            }
            if (-not $resultsByPath[$key].Pattern.Contains([string]$rule.Pattern)) {
                $resultsByPath[$key].Pattern.Add([string]$rule.Pattern) | Out-Null
            }
            $resultsByPath[$key].Count += $matched.Count
        }
    }

    return $resultsByPath.Values | Sort-Object RelativePath
}

# ── Main execution ────────────────────────────────────────────────────────────
Show-AppBanner -Text 'New Local User'

# ── Phase 2: Password resolution ─────────────────────────────────────────────
Show-AppRule -Title 'Password'

$envFilePath = Get-EnvFilePath
$envPlain    = Get-EnvPassword -EnvFilePath $envFilePath

if ($envPlain) {
    Write-AppHost '[grey].env file found — press [bold]Enter[/] to use stored password.[/]'
} else {
    Write-AppHost '[yellow]Warning: No .env file found. You must enter a password.[/]'
    Write-AppHost '[grey]  (Press Ctrl+C at any time to cancel.)[/]'
}

$securePassword = $null

while ($null -eq $securePassword) {
    Write-AppHost 'Password: ' -NoNewline
    $inputSecure = Read-Host -AsSecureString

    $inputPlain = ConvertTo-PlainText -SecureString $inputSecure

    if ([string]::IsNullOrEmpty($inputPlain)) {
        if ($envPlain) {
            # blank + .env present → use .env value
            $securePassword = ConvertTo-SecureString -String $envPlain -AsPlainText -Force
        } else {
            Write-AppHost '[red]Password cannot be blank when no .env file is present.[/]'
            # loop continues
        }
    } else {
        # Non-blank: require confirmation
        Write-AppHost 'Confirm password: ' -NoNewline
        $confirmSecure = Read-Host -AsSecureString
        $confirmPlain  = ConvertTo-PlainText -SecureString $confirmSecure

        if ($inputPlain -ne $confirmPlain) {
            Write-AppHost '[red]Passwords do not match. Please try again.[/]'
            # loop continues
        } else {
            $securePassword = $inputSecure
        }
    }
}

# Offer to persist the interactively-entered password to a new .env file
if ([string]::IsNullOrEmpty($envFilePath)) {
    $saveEnv = Read-AppConfirm -Message 'No .env file found. Save password to .env for future use?'
    if ($saveEnv) {
        $pwToSave   = ConvertTo-PlainText -SecureString $securePassword
        $envNewPath = Join-Path (Join-Path $PSScriptRoot '..\..') '.env'
        Set-Content -Path $envNewPath -Value "NEW_USER_PASSWORD=$pwToSave" -Encoding UTF8
        $pwToSave = $null
        Write-AppHost '[green].env file created at solution root.[/]'
    }
}

# ── Phase 3: Username resolution ─────────────────────────────────────────────
Show-AppRule -Title 'Username'

$baseName  = Get-BaseName
$suggested = Get-NextUsername -BaseName $baseName

$username = $null
while ($null -eq $username) {
    $rawInput = Read-AppText -Message 'Username' -DefaultAnswer $suggested
    $trimmed  = $rawInput.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Write-AppHost '[red]Username cannot be blank.[/]'
        continue
    }
    $existing = try { Get-LocalUser -Name $trimmed -ErrorAction Stop } catch { $null }
    if ($null -ne $existing) {
        Write-AppHost "[red]'$trimmed' is already in use. Choose a different username.[/]"
        continue
    }
    $username = $trimmed
}

# ── Phase 4: Confirmation ─────────────────────────────────────────────────────
Show-AppRule -Title 'Confirm'

$summaryText = (@(
    "Username                 : $username"
    "Password Never Expires   : True"
    "User May Not Change Pwd  : True"
    "Group                    : Administrators"
    "Computer                 : $env:COMPUTERNAME"
) -join "`n")

Show-AppSummary -Header 'New User Summary' -Data $summaryText

$confirmed = Read-AppConfirm -Message 'Create this user?'
if (-not $confirmed) {
    Write-AppHost '[yellow]Aborted.[/]'
    return
}

# ── Phase 5: User creation ────────────────────────────────────────────────────
$createUsername = $username
$createPassword = $securePassword
Invoke-AppStatus -Title 'Creating local user...' -ScriptBlock {
    $null = New-LocalUser `
        -Name $createUsername `
        -Password $createPassword `
        -PasswordNeverExpires:$true `
        -UserMayNotChangePassword:$true

    Add-LocalGroupMember -Group 'Administrators' -Member $createUsername
}

# ── Phase 6: Verification ─────────────────────────────────────────────────────
Show-AppRule -Title 'Verification'

$verifiedUser  = Get-LocalUser -Name $username
$groupMembers = try {
    Get-LocalGroupMember -Group 'Administrators'
} catch {
    # Error 1789 (trust failure) occurs on domain-joined machines when the DC is
    # unreachable and domain accounts exist in the local group. Creation succeeded;
    # only verification is affected.
    Write-AppHost "[yellow]Warning: Could not verify group membership ($_). Account was added successfully.[/]"
    $null
}
$isMember = $groupMembers | Where-Object { $_.Name -like "*\$username" }

[PSCustomObject]@{
    Name                     = $verifiedUser.Name
    Enabled                  = $verifiedUser.Enabled
    PasswordNeverExpires     = $null -eq $verifiedUser.PasswordExpires
    UserMayNotChangePassword = -not $verifiedUser.UserMayChangePassword
    'Member of Administrators' = if ($null -eq $groupMembers) { 'Unknown' } elseif ($isMember) { 'Yes' } else { 'No' }
} | Format-Table -AutoSize

# ── Phase 7: Auto-logon offer ─────────────────────────────────────────────────
$previousUsername     = $env:USERNAME
$migrationConfigPath  = Join-Path $PSScriptRoot 'ProfileMigrationPatterns.json'
$migrationCandidates  = Get-ProfileMigrationCandidates -CurrentProfilePath $env:USERPROFILE -ConfigPath $migrationConfigPath
$migrateProfileAssets = $false

if ($migrationCandidates.Count -gt 0) {
    Show-AppRule -Title 'Profile Migration'
    Write-AppHost "[cyan]Found files under '$previousUsername' that can be migrated after first logon:[/]"
    foreach ($candidate in $migrationCandidates) {
        $patterns = ($candidate.Pattern | Sort-Object) -join ', '
        Write-AppHost ("[grey]- {0} ({1}) : {2} file(s)[/]" -f $candidate.RelativePath, $patterns, $candidate.Count)
    }
    $migrateProfileAssets = Read-AppConfirm -Message "Migrate these files into '$username' after first logon?"
}

$logon = Read-AppConfirm -Message "Log on as '$username' now?"
if ($logon) {
    if ($migrateProfileAssets) {
        $postLogonScript = Join-Path $PSScriptRoot 'Invoke-ProfileMigrationPostLogon.ps1'
        $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        $runOnceValue = @(
            'powershell.exe'
            '-NoProfile'
            '-ExecutionPolicy Bypass'
            ('-File ' + (ConvertTo-CommandLineArgument -Value $postLogonScript))
            ('-PreviousUserName ' + (ConvertTo-CommandLineArgument -Value $previousUsername))
            ('-NewUserName ' + (ConvertTo-CommandLineArgument -Value $username))
            ('-ConfigPath ' + (ConvertTo-CommandLineArgument -Value $migrationConfigPath))
        ) -join ' '
        # '!' prefix tells Winlogon to delete the RunOnce entry only after the command
        # exits with code 0. Without it, the entry is deleted before execution, so a UAC
        # denial would lose the migration permanently.
        Set-ItemProperty -Path $runOncePath -Name '!OSM_ProfileMigration' -Value $runOnceValue -Type String
        Write-AppHost "[grey]Profile migration queued for first logon of '$username'.[/]"
    }

    $plainPassword = ConvertTo-PlainText -SecureString $securePassword
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $regPath -Name 'AutoAdminLogon'    -Value '1'
    Set-ItemProperty -Path $regPath -Name 'DefaultUserName'   -Value $username
    Set-ItemProperty -Path $regPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME
    Set-ItemProperty -Path $regPath -Name 'DefaultPassword'   -Value $plainPassword
    # AutoLogonCount is decremented by Winlogon after each auto-logon. Setting it
    # to 1 ensures only a single automatic logon occurs, after which Winlogon clears
    # AutoAdminLogon automatically. This is the primary one-time auto-logon mechanism.
    Set-ItemProperty -Path $regPath -Name 'AutoLogonCount'    -Value 1 -Type DWord
    $plainPassword = $null  # clear the reference

    # Suppress the Windows privacy settings screen on first logon.
    # DisablePrivacyExperience bypasses the OOBE privacy page for local accounts,
    # preventing prompts for Location, Find My Device, Inking & Typing, and
    # Tailored Services. This is a machine-wide policy and persists after reboot.
    $oobePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
    if (-not (Test-Path $oobePath)) { $null = New-Item -Path $oobePath -Force }
    Set-ItemProperty -Path $oobePath -Name 'DisablePrivacyExperience' -Value 1 -Type DWord

    # Register a one-shot scheduled task (SYSTEM, highest privilege) as a backup
    # cleanup mechanism. It fires on the first logon after reboot and clears all
    # auto-logon registry keys, then deletes itself.
    # An any-user AtLogOn trigger is used intentionally: user-specific triggers can
    # silently fail to fire during Winlogon's auto-logon path. Because the task
    # self-destructs on first fire, it runs exactly once regardless of who logs on.
    $clearCmd = @"
`$regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty    -Path `$regPath -Name 'AutoAdminLogon'  -Value '0'   -ErrorAction SilentlyContinue
Remove-ItemProperty -Path `$regPath -Name 'DefaultPassword'              -ErrorAction SilentlyContinue
Remove-ItemProperty -Path `$regPath -Name 'DefaultUserName'              -ErrorAction SilentlyContinue
Remove-ItemProperty -Path `$regPath -Name 'DefaultDomainName'            -ErrorAction SilentlyContinue
Remove-ItemProperty -Path `$regPath -Name 'AutoLogonCount'               -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'OSM_ClearAutoLogon' -Confirm:`$false -ErrorAction SilentlyContinue
"@
    $encoded   = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($clearCmd))
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -RunLevel Highest -UserId 'SYSTEM'
    Register-ScheduledTask -TaskName 'OSM_ClearAutoLogon' `
        -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    Write-AppHost '[grey]Auto-logon configured (one-time). Rebooting now...[/]'
    Invoke-Reboot
}
