#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-elevating launcher for New-LocalUser.ps1.

.DESCRIPTION
    If the current process is not running as Administrator, re-launches this
    script with elevation (UAC prompt). Otherwise invokes New-LocalUser.ps1
    directly in the same session.

.NOTES
    Run this script instead of invoking New-LocalUser.ps1 directly.
    Usage:  pwsh -File scripts\Start-App.ps1
            (or just double-click from Explorer)
#>

$scriptRoot = $PSScriptRoot
$target     = Join-Path $scriptRoot '..\src\Pwsh-NewLocalUser\New-LocalUser.ps1'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Re-launch with elevation; -Wait keeps the UAC dialog in foreground
    Start-Process pwsh `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$target`"" `
        -Verb RunAs `
        -Wait
} else {
    & $target
}
