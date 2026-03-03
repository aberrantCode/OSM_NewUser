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
    $resolved = Resolve-Path (Join-Path $PSScriptRoot '..\..' '.env') -ErrorAction SilentlyContinue
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

# ── Helper: logoff wrapper (mockable in Pester) ───────────────────────────────
function Invoke-Logoff { logoff }

# ── Main execution ────────────────────────────────────────────────────────────
Write-SpectreFigletText -Text 'New Local User'

# ── Phase 2: Password resolution ─────────────────────────────────────────────
Write-SpectreRule -Title 'Password'

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
