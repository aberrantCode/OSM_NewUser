#Requires -Version 5.1
<#
.SYNOPSIS
    Ensures the .NET 9 SDK is present, then starts the OsmUserWeb server.

.PARAMETER NoBrowser
    Skip automatically opening the browser after the server starts.
#>
[CmdletBinding()]
param(
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$RequiredMajor  = 9
$ServerUrl      = 'http://localhost:5150'
$ProjectRoot    = $PSScriptRoot

# ── Step 1: Check for a .NET 9 SDK ───────────────────────────────────────────
Write-Host 'Checking for .NET SDK...' -ForegroundColor Cyan

$sdkFound = $false
try {
    $sdks = & dotnet --list-sdks 2>$null
    $sdkFound = $sdks | Where-Object { $_ -match "^$RequiredMajor\." }
}
catch {
    # dotnet not on PATH at all — fall through to install
}

if ($sdkFound) {
    Write-Host "  .NET $RequiredMajor SDK found: $($sdkFound | Select-Object -Last 1)" -ForegroundColor Green
}
else {
    Write-Host "  .NET $RequiredMajor SDK not found. Installing via winget..." -ForegroundColor Yellow

    # Confirm winget is available
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'ERROR: winget is not available on this machine.' -ForegroundColor Red
        Write-Host '       Install the .NET 9 SDK manually: https://dotnet.microsoft.com/download/dotnet/9' -ForegroundColor Red
        throw 'winget not found.'
    }

    winget install --id Microsoft.DotNet.SDK.9 --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'ERROR: winget install failed.' -ForegroundColor Red
        throw "winget exited with code $LASTEXITCODE."
    }

    # Refresh PATH so dotnet is available in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')

    Write-Host "  .NET $RequiredMajor SDK installed." -ForegroundColor Green
}

# ── Step 2: Launch the server ─────────────────────────────────────────────────
Write-Host ''
Write-Host "Starting OsmUserWeb at $ServerUrl" -ForegroundColor Cyan
Write-Host '  Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoBrowser) {
    # Open the browser a moment after the server starts
    $null = Start-Job -ScriptBlock {
        param($url)
        Start-Sleep -Seconds 2
        Start-Process $url
    } -ArgumentList $ServerUrl
}

Push-Location $ProjectRoot
try {
    dotnet run
}
finally {
    Pop-Location
}
