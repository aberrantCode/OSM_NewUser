#Requires -Version 5.1
<#
.SYNOPSIS
    Remote installer and self-updater for OSM New-LocalUser.

.DESCRIPTION
    Downloads the latest release of OSM_NewUser from GitHub, installs it to
    C:\osm\new-localuser, merges any existing .env, and optionally launches the app.

.NOTES
    Remote one-liner (run from an elevated PowerShell):
        irm 'https://raw.githubusercontent.com/aberrantCode/OSM_NewUser/main/install.ps1' | iex

    The script auto-elevates if not already running as Administrator.
#>

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 defaults to SSL3/TLS1.0, which GitHub rejects. Force
# TLS 1.2 so the API/download calls below succeed. No-op on PowerShell 7+.
if ($PSVersionTable.PSEdition -ne 'Core') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ── Constants ─────────────────────────────────────────────────────────────────
$InstallDir   = 'C:\osm\new-localuser'
$ApiUrl       = 'https://api.github.com/repos/aberrantCode/OSM_NewUser/releases/latest'
$RawInstallerUrl = 'https://raw.githubusercontent.com/aberrantCode/OSM_NewUser/main/install.ps1'

# ── Auto-elevation ────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Prefer PowerShell 7 (pwsh) but fall back to Windows PowerShell when it is
    # not installed, so the one-liner works on a stock machine.
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $oneLiner = "Invoke-Expression (Invoke-RestMethod '$RawInstallerUrl')"
    Start-Process $psExe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$oneLiner`"" `
        -Verb RunAs `
        -Wait
    exit
}

# ── Step 1: Resolve latest release via GitHub API ────────────────────────────
Write-Host 'Checking for latest release...' -ForegroundColor Cyan
try {
    $release = Invoke-RestMethod -Uri $ApiUrl -TimeoutSec 10 -ErrorAction Stop
} catch {
    Write-Warning "GitHub API unreachable: $_"
    Write-Warning 'Cannot check for updates. Exiting.'
    exit 0
}

$tag     = $release.tag_name          # e.g. "v1.0.0"
$version = $tag -replace '^v', ''     # e.g. "1.0.0"

# ── Step 2: Check installed version ──────────────────────────────────────────
$versionFile     = Join-Path $InstallDir 'version.txt'
$installedVersion = $null

if (Test-Path $versionFile) {
    $installedVersion = (Get-Content $versionFile -Raw).Trim()
}

if ($installedVersion -eq $version) {
    Write-Host "Already up to date (v$version)." -ForegroundColor Green
    # Skip to run prompt (step 9)
} else {
    if ($installedVersion) {
        Write-Host "Updating v$installedVersion → v$version..." -ForegroundColor Cyan
    } else {
        Write-Host "Installing v$version..." -ForegroundColor Cyan
    }

    # ── Step 3: Backup .env ───────────────────────────────────────────────────
    $envPath   = Join-Path $InstallDir '.env'
    $envBackup = $null

    if (Test-Path $envPath) {
        $envBackup = Get-Content $envPath -Raw -ErrorAction SilentlyContinue
        Write-Host 'Backed up existing .env.' -ForegroundColor DarkGray
    }

    # ── Step 4: Download release ZIP ─────────────────────────────────────────
    $zipUrl  = "https://github.com/aberrantCode/OSM_NewUser/archive/refs/tags/$tag.zip"
    $zipPath = Join-Path $env:TEMP "OSM_NewUser-$tag.zip"

    Write-Host "Downloading $zipUrl ..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Warning "Download failed: $_"
        Write-Warning 'Existing install left untouched.'
        exit 1
    }

    # ── Step 5: Install ───────────────────────────────────────────────────────
    # Extract and validate into staging FIRST. Only after we have a confirmed,
    # well-formed payload do we touch the existing install — so a failed download
    # or malformed ZIP can never leave the machine with no install.
    $stagingDir = Join-Path $env:TEMP "OSM_NewUser-staging-$tag"
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }

    Expand-Archive -Path $zipPath -DestinationPath $stagingDir -Force

    # The ZIP extracts to a single root folder (e.g. OSM_NewUser-1.0.0)
    $extractedRoot = Get-ChildItem -Path $stagingDir -Directory | Select-Object -First 1

    if (-not $extractedRoot) {
        Write-Warning 'Unexpected ZIP structure: no root folder found.'
        Write-Warning 'Existing install left untouched.'
        Remove-Item -Path $zipPath    -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Payload is good — now swap it in.
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }

    # Move-Item does not create missing parent directories, so on a first-time
    # install (where C:\osm does not exist yet) we must create the parent first.
    $installParent = Split-Path -Path $InstallDir -Parent
    if (-not (Test-Path $installParent)) {
        New-Item -ItemType Directory -Path $installParent -Force | Out-Null
    }

    Move-Item -Path $extractedRoot.FullName -Destination $InstallDir

    # Cleanup temp files
    Remove-Item -Path $zipPath    -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Installed to $InstallDir." -ForegroundColor Green

    # ── Step 6: Write version file ────────────────────────────────────────────
    Set-Content -Path (Join-Path $InstallDir 'version.txt') -Value $version -Encoding UTF8

    # ── Step 7: Restore and merge .env ───────────────────────────────────────
    $envExamplePath = Join-Path $InstallDir '.env.example'

    if ($envBackup) {
        # Parse backup: key → value
        $backupDict = @{}
        foreach ($line in ($envBackup -split "`n")) {
            $line = $line.Trim()
            if ($line -match '^([^#=][^=]*)=(.*)$') {
                $backupDict[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }

        # Parse .env.example: key → default value (skip comment lines)
        $exampleDict = @{}
        if (Test-Path $envExamplePath) {
            foreach ($line in (Get-Content $envExamplePath)) {
                $line = $line.Trim()
                if ($line -match '^([^#=][^=]*)=(.*)$') {
                    $exampleDict[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
        }

        # Merge: backup values take priority; new keys from example get defaults.
        $merged = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $exampleDict.Keys) {
            if ($backupDict.ContainsKey($key)) {
                $merged.Add("$key=$($backupDict[$key])")
            } else {
                $merged.Add("$key=$($exampleDict[$key])")
            }
        }
        # Preserve any user-defined keys not present in .env.example so a reinstall
        # never silently drops them (and so the file is never emptied if the new
        # release happens to ship without a .env.example).
        foreach ($key in $backupDict.Keys) {
            if (-not $exampleDict.ContainsKey($key)) {
                $merged.Add("$key=$($backupDict[$key])")
            }
        }

        $mergedEnvPath = Join-Path $InstallDir '.env'
        Set-Content -Path $mergedEnvPath -Value ($merged -join "`n") -Encoding UTF8
        Write-Host '.env merged (existing values preserved).' -ForegroundColor DarkGray
    }
    # If no backup existed, leave .env absent — New-LocalUser.ps1 handles missing .env interactively
}

# ── Step 8: Install PwshSpectreConsole if missing ────────────────────────────
$spectreInstalled = Get-Module PwshSpectreConsole -ListAvailable
if (-not $spectreInstalled) {
    Write-Host 'Installing PwshSpectreConsole module...' -ForegroundColor Cyan
    Install-Module PwshSpectreConsole -RequiredVersion 2.3.0 -Scope AllUsers -Force
    Write-Host 'PwshSpectreConsole installed.' -ForegroundColor Green
}

# ── Step 9: Prompt to run ─────────────────────────────────────────────────────
$startScript = Join-Path $InstallDir 'scripts\Start-App.ps1'

if (-not $env:OSM_INSTALL_SKIP_RUN_PROMPT) {
    $answer = Read-Host 'Run New-LocalUser.ps1 now? [Y/N]'
    if ($answer -match '^[Yy]') {
        if (Test-Path $startScript) {
            & $startScript
        } else {
            Write-Warning "Start-App.ps1 not found at: $startScript"
        }
    }
}
