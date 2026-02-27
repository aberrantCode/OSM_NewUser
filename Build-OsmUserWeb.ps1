#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the OsmUserWeb application and packages it with the installer scripts.

.DESCRIPTION
    1. Derives the build version from version.json (MAJOR.MINOR) and the git
       commit count (PATCH), producing a version string like "1.0.47".
    2. Runs dotnet publish on OsmUserWeb.csproj, injecting the version into the
       binary's FileVersion and InformationalVersion metadata.
    3. Assembles a self-contained distribution folder under .\dist\ containing:
         app\        - the published .NET binaries
         *.ps1       - all installer / uninstaller / helper scripts
         version.txt - build manifest (version, SHA, timestamp)
    4. Optionally zips the distribution folder, named OsmUserWeb-v<VERSION>-<RUNTIME>.zip.

    Version scheme:  MAJOR.MINOR.PATCH[+SHA]
      MAJOR.MINOR  — edit version.json to bump for significant releases
      PATCH        — git rev-list --count HEAD  (increments automatically with every commit)
      +SHA         — short commit hash appended to InformationalVersion for traceability

    See the "Versioning" section of src/DotNetWebServer/README.md for full details.

.PARAMETER Configuration
    Build configuration. Default: Release

.PARAMETER Runtime
    .NET runtime identifier. Default: win-x64

.PARAMETER SelfContained
    When set, publishes as a self-contained executable (bundles the .NET runtime).
    Default: false (framework-dependent; requires ASP.NET Core 9 on the target server).

.PARAMETER OutputDir
    Root output directory for the distribution folder. Default: .\dist

.PARAMETER ZipOutput
    When set, zips the completed distribution folder alongside it.
    The archive is named OsmUserWeb-v<VERSION>-<RUNTIME>.zip.

.PARAMETER Clean
    When set, removes existing build artifacts (bin\, obj\, publish\, dist\) before building.

.EXAMPLE
    # Standard framework-dependent build
    .\Build-OsmUserWeb.ps1

.EXAMPLE
    # Self-contained build, zipped for distribution
    .\Build-OsmUserWeb.ps1 -SelfContained -ZipOutput

.EXAMPLE
    # Clean build with custom output directory
    .\Build-OsmUserWeb.ps1 -Clean -OutputDir C:\Builds\OsmUserWeb
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [string] $Runtime = 'win-x64',

    [switch] $SelfContained,

    [string] $OutputDir = (Join-Path $PSScriptRoot 'dist'),

    [switch] $ZipOutput,

    [switch] $Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────────────────
$projectRoot  = $PSScriptRoot
$webDir       = Join-Path $projectRoot 'src\DotNetWebServer'
$projectFile  = Join-Path $webDir 'OsmUserWeb.csproj'
$testProject  = Join-Path $projectRoot 'src\OsmUserWeb.Tests\OsmUserWeb.Tests.csproj'
$publishDir   = Join-Path $webDir 'publish'
$versionFile  = Join-Path $projectRoot 'version.json'

$distApp      = Join-Path $OutputDir 'app'

$installerScripts = @(
    'Install-OsmUserWeb.ps1'
    'Install-OsmUserWeb-Remote.ps1'
    'Uninstall-OsmUserWeb.ps1'
    'Uninstall-OsmUserWeb-Remote.ps1'
    'Start-OsmUserWeb.ps1'
    'Update-OsmUserWeb.ps1'
    'Diagnose-OsmUserWeb.ps1'
    'ScriptHelpers.ps1'     # shared helper functions; dot-sourced by the installers
    'INSTALL.md'
    'README.md'
)

# ── Helpers ────────────────────────────────────────────────────────────────────
function Write-Step([string] $message) {
    Write-Host "`n==> $message" -ForegroundColor Cyan
}

function Write-Success([string] $message) {
    Write-Host "    [OK] $message" -ForegroundColor Green
}

function Assert-ExitCode([string] $command) {
    if ($LASTEXITCODE -ne 0) {
        Write-Error "'$command' exited with code $LASTEXITCODE. Build aborted."
    }
}

# ── Validate prerequisites ─────────────────────────────────────────────────────
Write-Step 'Checking prerequisites'

if (-not (Test-Path $projectFile)) {
    Write-Error "Project file not found: $projectFile"
}

if (-not (Test-Path $versionFile)) {
    Write-Error "version.json not found at repo root: $versionFile"
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Error "'dotnet' was not found in PATH. Install the .NET 9 SDK and try again."
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Error "'git' was not found in PATH. Git is required to compute the build version."
}

$sdkVersion = & dotnet --version 2>&1
Write-Success "dotnet SDK: $sdkVersion"

# ── Compute version ────────────────────────────────────────────────────────────
Write-Step 'Computing build version'

$versionJson  = Get-Content $versionFile -Raw | ConvertFrom-Json
$major        = [int]$versionJson.major
$minor        = [int]$versionJson.minor

# PATCH = total number of commits reachable from HEAD (increments with every commit)
# stderr suppressed: we detect failure via LASTEXITCODE; mixing stderr into the
# captured string (2>&1) would corrupt the version if git emits any warnings.
$patch = (& git -C $projectRoot rev-list --count HEAD 2>$null)
Assert-ExitCode 'git rev-list --count HEAD'
$patch = "$patch".Trim()

# Short SHA for InformationalVersion traceability
$shortSha = (& git -C $projectRoot rev-parse --short HEAD 2>$null)
Assert-ExitCode 'git rev-parse --short HEAD'
$shortSha = "$shortSha".Trim()

# Warn if this looks like a shallow clone (commit count will be misleading)
$isShallow = Test-Path (Join-Path $projectRoot '.git\shallow')
if ($isShallow) {
    Write-Warning 'Shallow clone detected — commit count may be inaccurate. Consider running: git fetch --unshallow'
}

$Version             = "$major.$minor.$patch"
$InformationalVersion = "$Version+$shortSha"

Write-Success "Version              : $Version"
Write-Success "InformationalVersion : $InformationalVersion"

# ── Optional clean ─────────────────────────────────────────────────────────────
if ($Clean) {
    Write-Step 'Cleaning existing artifacts'

    foreach ($dir in @(
        (Join-Path $webDir 'bin'),
        (Join-Path $webDir 'obj'),
        $publishDir,
        $OutputDir
    )) {
        if (Test-Path $dir) {
            Remove-Item $dir -Recurse -Force
            Write-Success "Removed $dir"
        }
    }
}

# ── Pester tests (PowerShell script helpers) ───────────────────────────────────
Write-Step 'Running Pester tests'

$pesterAvailable = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pesterAvailable) {
    Write-Host '    Pester 5 not found — installing for CurrentUser...'
    Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0 -Repository PSGallery
    Import-Module Pester -MinimumVersion 5.0
} else {
    Import-Module Pester -RequiredVersion $pesterAvailable.Version
}

$pesterDir    = Join-Path $projectRoot 'tests\Pester'
$pesterCfg    = New-PesterConfiguration
$pesterCfg.Run.Path      = $pesterDir
$pesterCfg.Run.PassThru  = $true
$pesterCfg.Output.Verbosity = 'Normal'

# Suspend strict mode while Pester runs: Pester 5 evaluates It-block name
# templates (e.g. <paramName>) by expanding $paramName from scope.  Under
# Set-StrictMode -Version Latest any undefined variable throws instead of
# returning $null, which breaks tests that have angle-bracket text in names.
Set-StrictMode -Off
$pesterResult = Invoke-Pester -Configuration $pesterCfg
Set-StrictMode -Version Latest

if ($pesterResult.FailedCount -gt 0) {
    Write-Error "Pester: $($pesterResult.FailedCount) test(s) failed. Build aborted."
}
Write-Success "Pester: $($pesterResult.PassedCount) test(s) passed."

# ── dotnet test ────────────────────────────────────────────────────────────────
Write-Step "Running dotnet tests ($Configuration)"

& dotnet test $testProject '--configuration' $Configuration
Assert-ExitCode 'dotnet test'

Write-Success 'All tests passed.'

# ── dotnet publish ─────────────────────────────────────────────────────────────
Write-Step "Publishing OsmUserWeb ($Configuration | $Runtime | self-contained: $($SelfContained.IsPresent))"

$publishArgs = @(
    'publish'
    $projectFile
    '--configuration', $Configuration
    '--runtime',       $Runtime
    '--output',        $publishDir
    "--property:Version=$Version"
    "--property:InformationalVersion=$InformationalVersion"
)

if ($SelfContained) {
    $publishArgs += '--self-contained', 'true'
} else {
    $publishArgs += '--self-contained', 'false'
}

& dotnet @publishArgs
Assert-ExitCode 'dotnet publish'

Write-Success "Published to: $publishDir"

# ── Assemble distribution folder ───────────────────────────────────────────────
Write-Step "Assembling distribution folder: $OutputDir"

# Copy published binaries
if (Test-Path $distApp) { Remove-Item $distApp -Recurse -Force }
Copy-Item -Path $publishDir -Destination $distApp -Recurse -Force
Write-Success "Copied binaries to: $distApp"

# Copy installer scripts
foreach ($fileName in $installerScripts) {
    $src = Join-Path $webDir $fileName
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $OutputDir -Force
        Write-Success "Copied $fileName"
    } else {
        Write-Warning "    [SKIP] Not found: $src"
    }
}

# Write version manifest
$versionManifest = @"
OsmUserWeb Build Manifest
=========================
Version              : $Version
InformationalVersion : $InformationalVersion
Configuration        : $Configuration
Runtime              : $Runtime
Self-contained       : $($SelfContained.IsPresent)
Build date (UTC)     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC
"@

$versionManifest | Set-Content -Path (Join-Path $OutputDir 'version.txt') -Encoding UTF8
Write-Success 'Wrote version.txt'

# ── Optional zip ──────────────────────────────────────────────────────────────
$zipPath = $null
if ($ZipOutput) {
    Write-Step 'Creating zip archive'

    $zipName = "OsmUserWeb-v$Version-$Runtime.zip"
    $zipPath = Join-Path (Split-Path $OutputDir -Parent) $zipName

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($OutputDir, $zipPath)

    Write-Success "Archive created: $zipPath"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════╗' -ForegroundColor Green
Write-Host '║                  Build complete                      ║' -ForegroundColor Green
Write-Host '╚══════════════════════════════════════════════════════╝' -ForegroundColor Green
Write-Host ''
Write-Host "  Version        : $Version"
Write-Host "  Full version   : $InformationalVersion"
Write-Host "  Configuration  : $Configuration"
Write-Host "  Runtime        : $Runtime"
Write-Host "  Self-contained : $($SelfContained.IsPresent)"
Write-Host "  Distribution   : $OutputDir"
if ($null -ne $zipPath) {
    Write-Host "  Archive        : $zipPath"
}
Write-Host ''
Write-Host "To install on the target server, copy the distribution folder and run:" -ForegroundColor Yellow
Write-Host "  .\Install-OsmUserWeb.ps1 -PublishPath .\app" -ForegroundColor Yellow
Write-Host ''
