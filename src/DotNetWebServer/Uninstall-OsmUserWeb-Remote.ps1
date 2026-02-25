#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates a remote uninstallation of OsmUserWeb from an admin workstation.

.DESCRIPTION
    Mirrors Install-OsmUserWeb-Remote.ps1 — runs the uninstaller on a remote server
    via PS Remoting, avoiding the need to log on locally to the target machine.

      LOCAL (this workstation, where RSAT is available):
        - Verify prerequisites and collect configuration inputs
        - Optionally remove the svc-osmweb Active Directory account

      REMOTE (target server, via Invoke-Command over WinRM):
        - Stop and delete the Windows Service
        - Remove HTTP.sys URL ACL and SSL cert bindings
        - Remove Windows Firewall rules
        - Delete application files
        - Optionally remove the self-signed certificate

    Prerequisites on the admin workstation:
      - PowerShell 5.1+
      - RSAT / ActiveDirectory module (only required when -RemoveServiceAccount is used)
      - WinRM connectivity to the target server (Test-NetConnection <server> -Port 5985)

    Prerequisites on the target server:
      - WinRM enabled (Enable-PSRemoting)
      - The supplied -Credential must be a local Administrator

.PARAMETER TargetServer
    Hostname or IP of the target server.

.PARAMETER Credential
    Credentials for the PS Remoting session. Must have local Administrator rights
    on the target server. Defaults to the current user's credentials.

.PARAMETER InstallPath
    Service installation directory on the target server. Default: C:\Services\OsmUserWeb

.PARAMETER SvcAccountName
    SAM account name of the service account. Default: svc-osmweb

.PARAMETER RemoveServiceAccount
    Also delete the svc-osmweb Active Directory account.  Handled locally on the
    admin workstation via RSAT (requires the ActiveDirectory module).

.PARAMETER RemoveCertificate
    Also remove the OsmUserWeb self-signed certificate (CN=<hostname>) from the
    target server's Cert:\LocalMachine\My store.

.EXAMPLE
    # Minimal — connect as current user
    .\Uninstall-OsmUserWeb-Remote.ps1 -TargetServer AC-WINADMIN

.EXAMPLE
    # Remove everything including the service account and certificate
    .\Uninstall-OsmUserWeb-Remote.ps1 -TargetServer AC-WINADMIN -RemoveServiceAccount -RemoveCertificate

.EXAMPLE
    # Fully specified with explicit credentials
    .\Uninstall-OsmUserWeb-Remote.ps1 `
        -TargetServer         AC-WINADMIN `
        -Credential           (Get-Credential "opbta\Administrator") `
        -InstallPath          'C:\Services\OsmUserWeb' `
        -RemoveServiceAccount `
        -RemoveCertificate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetServer,

    [PSCredential]$Credential,

    [string]$InstallPath       = 'C:\Services\OsmUserWeb',
    [string]$SvcAccountName    = 'svc-osmweb',
    [switch]$RemoveServiceAccount,
    [switch]$RemoveCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Msg) Write-Host "`n  >> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }

# ==============================================================================

Write-Host "`n  +======================================================+" -ForegroundColor Yellow
Write-Host "  |       OsmUserWeb - Remote Uninstaller                |" -ForegroundColor Yellow
Write-Host "  +======================================================+`n" -ForegroundColor Yellow

# -- Step 0: Local prerequisites -------------------------------------------
Write-Step 'Step 0 . Checking local prerequisites'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as Administrator on the admin workstation.'
}
Write-Ok 'Running as Administrator.'

# The local uninstaller is copied to the remote server and executed there
$uninstallerScript = Join-Path $PSScriptRoot 'Uninstall-OsmUserWeb.ps1'
if (-not (Test-Path $uninstallerScript)) {
    throw "Uninstall-OsmUserWeb.ps1 not found in $PSScriptRoot. Both scripts must be in the same directory."
}
Write-Ok "Uninstaller script found: $uninstallerScript"

# Determine where AD account removal will run.
# Prefer local (admin workstation) via RSAT; fall back to the remote server if RSAT is absent.
$removeAdLocally = $false
$removeAdRemotely = $false

if ($RemoveServiceAccount) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $removeAdLocally = $true
        Write-Ok 'ActiveDirectory (RSAT) module loaded — AD account will be removed locally.'
    } catch {
        $removeAdRemotely = $true
        Write-Warn 'RSAT (ActiveDirectory module) not found locally — AD account removal will run on the target server instead.'
    }
}

# -- Summary and confirmation -----------------------------------------------
Write-Host "  The following will be removed from ${TargetServer}:" -ForegroundColor DarkGray
Write-Host "    Windows Service  : OsmUserWeb"
Write-Host "    Application files: $InstallPath"
Write-Host "    Firewall rules   : OsmUserWeb*"
Write-Host "    HTTP.sys bindings: URL ACL and SSL cert (port read from registry)"
if ($RemoveCertificate)  { Write-Host '    Certificate      : self-signed cert (if bound via HTTP.sys)' }
if ($removeAdLocally)    { Write-Host "    AD account       : $SvcAccountName (removed locally via RSAT)" }
if ($removeAdRemotely)   { Write-Host "    AD account       : $SvcAccountName (removed on $TargetServer — no local RSAT)" }
Write-Host ''

$confirm = Read-Host '  Proceed? (Y/N)'
if ($confirm -notin 'Y', 'y') {
    Write-Host 'Aborted. No changes were made.' -ForegroundColor Yellow
    exit 0
}

# -- Step 1: Open PS Remoting session --------------------------------------
Write-Step "Step 1 . Opening PS Remoting session to $TargetServer"

$sessParams = @{ ComputerName = $TargetServer; ErrorAction = 'Stop' }
if ($Credential) { $sessParams['Credential'] = $Credential }
$sess = New-PSSession @sessParams
Write-Ok "Connected to $TargetServer"

$remoteTemp = "C:\Windows\Temp\OsmUninstall-$(New-Guid)"

try {
    # -- Step 2: Copy uninstaller to target server -------------------------
    Write-Step 'Step 2 . Copying uninstaller to target server'

    Invoke-Command -Session $sess -ScriptBlock {
        param($t)
        New-Item -ItemType Directory -Path $t -Force | Out-Null
    } -ArgumentList $remoteTemp

    Copy-Item -Path $uninstallerScript -Destination "$remoteTemp\" -ToSession $sess -Force
    Write-Ok 'Uninstaller script copied.'

    # -- Step 3: Run uninstaller on target server --------------------------
    Write-Step 'Step 3 . Running uninstaller on target server'

    # Convert switches to plain booleans so $using: captures them correctly
    $removeCertBool     = $RemoveCertificate.IsPresent
    $removeAdRemotelyBool = $removeAdRemotely

    Invoke-Command -Session $sess -ScriptBlock {
        $uninstallArgs = @{
            InstallPath    = $using:InstallPath
            SvcAccountName = $using:SvcAccountName
            Force          = $true   # non-interactive remote session
        }
        if ($using:removeCertBool)       { $uninstallArgs['RemoveCertificate']    = $true }
        # Pass RemoveServiceAccount to the remote script only when RSAT wasn't available locally
        if ($using:removeAdRemotelyBool) { $uninstallArgs['RemoveServiceAccount'] = $true }

        & "$using:remoteTemp\Uninstall-OsmUserWeb.ps1" @uninstallArgs
    }

} finally {
    # -- Step 4: Clean up remote staging directory -------------------------
    Write-Step 'Step 4 . Cleaning up remote temp files'
    try {
        Invoke-Command -Session $sess -ScriptBlock {
            param($t)
            Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
        } -ArgumentList $remoteTemp
        Write-Ok "Removed: $remoteTemp"
    } catch {
        Write-Warn "Could not remove remote temp dir $remoteTemp — remove it manually."
    }

    Remove-PSSession $sess -ErrorAction SilentlyContinue
    Write-Ok 'PS Remoting session closed.'
}

# -- Step 5: Remove AD service account (local, only when RSAT was available) ---
Write-Step 'Step 5 . Service account'

if ($removeAdLocally) {
    $adUser = Get-ADUser -Filter "SamAccountName -eq '$SvcAccountName'" -ErrorAction SilentlyContinue
    if ($adUser) {
        Remove-ADUser -Identity $adUser -Confirm:$false
        Write-Ok "AD account removed: $SvcAccountName"
    } else {
        Write-Skip "AD account not found: $SvcAccountName"
    }
} elseif ($removeAdRemotely) {
    Write-Ok "AD account removal was delegated to $TargetServer (see Step 3 output above)."
} else {
    Write-Skip 'Service account left in place (-RemoveServiceAccount not specified).'
}

# -- Done ------------------------------------------------------------------
Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host '  |       Remote Uninstall Complete                      |' -ForegroundColor Green
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host ''
