#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-elevating launcher for New-LocalUser.ps1.

.DESCRIPTION
    Checks for a newer installed release before doing anything else. If an
    update is available, installs it and relaunches the updated launcher. Then,
    if the current process is not running as Administrator, re-launches the app
    with elevation (UAC prompt). Otherwise invokes New-LocalUser.ps1 directly in
    the same session.

.NOTES
    Run this script instead of invoking New-LocalUser.ps1 directly.
    Usage:  pwsh -File scripts\Start-App.ps1
            (or just double-click from Explorer)
#>

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 defaults to SSL3/TLS1.0, which GitHub rejects. Force
# TLS 1.2 so the update-check call below succeeds. No-op on PowerShell 7+.
if ($PSVersionTable.PSEdition -ne 'Core') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Prefer PowerShell 7 (pwsh) but fall back to Windows PowerShell when it is not
# installed, so elevation relaunches work on a stock machine.
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

$scriptRoot = $PSScriptRoot
$installRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
$target     = Join-Path $scriptRoot '..\src\Pwsh-NewLocalUser\New-LocalUser.ps1'
$versionFile = Join-Path $installRoot 'version.txt'
$apiUrl = 'https://api.github.com/repos/aberrantCode/OSM_NewUser/releases/latest'
$rawInstallerUrl = 'https://raw.githubusercontent.com/aberrantCode/OSM_NewUser/main/install.ps1'

function Test-IsElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-SemanticVersion {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $normalized = $Value.Trim() -replace '^v', ''
    $version = $null

    if ([version]::TryParse($normalized, [ref]$version)) {
        return $version
    }

    return $null
}

function Invoke-UpdateCheck {
    param(
        [string]$InstallRoot,
        [string]$VersionFile,
        [string]$ApiUrl,
        [string]$RawInstallerUrl
    )

    # DEV-SAFE: local clones do not have version.txt, so update checks only run
    # in installs created by install.ps1.
    if (-not (Test-Path $VersionFile)) {
        return $false
    }

    $localVersionText = (Get-Content $VersionFile -Raw -ErrorAction SilentlyContinue).Trim()
    $localVersion = ConvertTo-SemanticVersion $localVersionText
    if (-not $localVersion) {
        Write-Warning "Cannot parse installed version '$localVersionText'. Skipping update check."
        return $false
    }

    try {
        $release = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 5 -ErrorAction Stop
    } catch {
        Write-Warning "Could not check for updates: $_"
        return $false
    }

    $latestVersionText = $release.tag_name -replace '^v', ''
    $latestVersion = ConvertTo-SemanticVersion $latestVersionText
    if (-not $latestVersion) {
        Write-Warning "Cannot parse latest release version '$($release.tag_name)'. Skipping update."
        return $false
    }

    if ($latestVersion -le $localVersion) {
        return $false
    }

    if (-not (Test-IsElevated)) {
        Write-Host "New version available (v$latestVersionText). Requesting elevation to update..." -ForegroundColor Cyan
        Start-Process $psExe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -Verb RunAs `
            -Wait
        return $true
    }

    Write-Host "New version available (v$latestVersionText). Updating..." -ForegroundColor Cyan
    $previousSkipRunPrompt = $env:OSM_INSTALL_SKIP_RUN_PROMPT

    try {
        $env:OSM_INSTALL_SKIP_RUN_PROMPT = '1'
        Invoke-Expression (Invoke-RestMethod -Uri $RawInstallerUrl -TimeoutSec 30 -ErrorAction Stop)
    } finally {
        if ($null -eq $previousSkipRunPrompt) {
            [System.Environment]::SetEnvironmentVariable('OSM_INSTALL_SKIP_RUN_PROMPT', $null, 'Process')
        } else {
            $env:OSM_INSTALL_SKIP_RUN_PROMPT = $previousSkipRunPrompt
        }
    }

    $updatedStartScript = Join-Path $InstallRoot 'scripts\Start-App.ps1'
    if (Test-Path $updatedStartScript) {
        Write-Host 'Update complete. Relaunching...' -ForegroundColor Green
        & $updatedStartScript
    } else {
        Write-Warning "Update completed, but Start-App.ps1 was not found at: $updatedStartScript"
    }

    return $true
}

if (Invoke-UpdateCheck -InstallRoot $installRoot -VersionFile $versionFile -ApiUrl $apiUrl -RawInstallerUrl $rawInstallerUrl) {
    exit
}

$isAdmin = Test-IsElevated

if (-not $isAdmin) {
    # Re-launch with elevation; -Wait keeps the UAC dialog in foreground
    Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$target`"" `
        -Verb RunAs `
        -Wait
} else {
    & $target
}
