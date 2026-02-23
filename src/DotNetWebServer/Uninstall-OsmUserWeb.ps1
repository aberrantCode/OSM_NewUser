#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the OsmUserWeb Windows Service and all associated configuration.

.DESCRIPTION
    Stops and deletes the Windows Service, removes HTTP.sys URL ACL and SSL cert
    bindings, removes Windows Firewall rules, and deletes the application files.

    Optionally removes the service account from Active Directory and/or the
    self-signed certificate from the machine certificate store.

.PARAMETER InstallPath
    Service installation directory.  Default: C:\Services\OsmUserWeb

.PARAMETER SvcAccountName
    SAM account name of the service account.  Default: svc-osmweb

.PARAMETER RemoveServiceAccount
    Also delete the svc-osmweb Active Directory account.

.PARAMETER RemoveCertificate
    Also remove the OsmUserWeb self-signed certificate (CN=<hostname>) from
    Cert:\LocalMachine\My.  Has no effect on certificates issued by a real CA.

.EXAMPLE
    .\Uninstall-OsmUserWeb.ps1

.EXAMPLE
    .\Uninstall-OsmUserWeb.ps1 -RemoveServiceAccount -RemoveCertificate
#>
[CmdletBinding()]
param(
    [string]$InstallPath       = 'C:\Services\OsmUserWeb',
    [string]$SvcAccountName    = 'svc-osmweb',
    [switch]$RemoveServiceAccount,
    [switch]$RemoveCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'OsmUserWeb'

function Write-Step { param([string]$Msg) Write-Host "`n  >> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }

# ==============================================================================

Write-Host "`n  +======================================================+" -ForegroundColor Yellow
Write-Host "  |       OsmUserWeb - Uninstaller                      |" -ForegroundColor Yellow
Write-Host "  +======================================================+`n" -ForegroundColor Yellow

# -- Admin check --------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as Administrator.'
}

# -- Discover port from registry env ------------------------------------------
$httpsPort = 8443   # default; overridden below if found in registry
$regPath   = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
if (Test-Path $regPath) {
    $regEnv = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).Environment
    $urlsEntry = $regEnv | Where-Object { $_ -like 'ASPNETCORE_URLS=*' }
    if ($urlsEntry) {
        $urlsValue = $urlsEntry -replace '^ASPNETCORE_URLS=', ''
        # Extract port from the https://+:<port> segment
        if ($urlsValue -match 'https://\+:(\d+)') {
            $httpsPort = [int]$Matches[1]
        }
    }
}

# -- Discover thumbprint registered with HTTP.sys for this port ---------------
$boundThumbprint = $null
$sslShow = & netsh http show sslcert "ipport=0.0.0.0:$httpsPort" 2>$null
if ($sslShow -match 'Certificate Hash\s+:\s+([0-9A-Fa-f]{40})') {
    $boundThumbprint = $Matches[1].ToUpper()
}

# -- Summary ------------------------------------------------------------------
Write-Host '  The following will be removed:' -ForegroundColor DarkGray
Write-Host "    Windows Service  : $ServiceName"
Write-Host "    Application files: $InstallPath"
Write-Host "    Firewall rules   : OsmUserWeb*"
Write-Host "    HTTP.sys URL ACL : https://+:$httpsPort/"
Write-Host "    HTTP.sys sslcert : 0.0.0.0:$httpsPort  [::]`:$httpsPort"
if ($RemoveServiceAccount) { Write-Host "    AD account       : $SvcAccountName" }
if ($RemoveCertificate -and $boundThumbprint) {
    Write-Host "    Certificate      : $boundThumbprint (CN=$env:COMPUTERNAME, if self-signed)"
}
Write-Host ''

$confirm = Read-Host '  Proceed? (Y/N)'
if ($confirm -notin 'Y', 'y') {
    Write-Host 'Aborted. No changes were made.' -ForegroundColor Yellow
    exit 0
}

# ==============================================================================

# -- 1. Stop and delete service -----------------------------------------------
Write-Step 'Step 1 . Stopping and removing Windows Service'

$svcExists = (& sc.exe query $ServiceName 2>$null) -join '' -match 'SERVICE_NAME'
if ($svcExists) {
    & sc.exe stop $ServiceName 2>$null | Out-Null
    $deadline = (Get-Date).AddSeconds(10)
    do { Start-Sleep -Milliseconds 500
    } while ((& sc.exe query $ServiceName) -join '' -match 'STATE.*4.*RUNNING' -and (Get-Date) -lt $deadline)

    & sc.exe delete $ServiceName | Out-Null
    Write-Ok 'Service stopped and deleted.'
} else {
    Write-Skip 'Service not found - already removed.'
}

# -- 2. HTTP.sys registrations ------------------------------------------------
Write-Step "Step 2 . Removing HTTP.sys registrations (port $httpsPort)"

$urlAcl = & netsh http show urlacl "url=https://+:$httpsPort/" 2>$null
if ($urlAcl -match 'Reserved URL') {
    & netsh http delete urlacl "url=https://+:$httpsPort/" | Out-Null
    Write-Ok "URL ACL removed: https://+:$httpsPort/"
} else {
    Write-Skip "No URL ACL found for https://+:$httpsPort/"
}

foreach ($ip in @('0.0.0.0', '[::]')) {
    $show = & netsh http show sslcert "ipport=${ip}:$httpsPort" 2>$null
    if ($show -match 'Certificate Hash') {
        & netsh http delete sslcert "ipport=${ip}:$httpsPort" | Out-Null
        Write-Ok "SSL cert binding removed: ${ip}:$httpsPort"
    } else {
        Write-Skip "No SSL cert binding found: ${ip}:$httpsPort"
    }
}

# -- 3. Firewall rules --------------------------------------------------------
Write-Step 'Step 3 . Removing firewall rules'

$fwRules = Get-NetFirewallRule -DisplayName 'OsmUserWeb*' -ErrorAction SilentlyContinue
if ($fwRules) {
    $fwRules | Remove-NetFirewallRule
    Write-Ok "Removed $($fwRules.Count) firewall rule(s)."
} else {
    Write-Skip 'No OsmUserWeb firewall rules found.'
}

# -- 4. Application files -----------------------------------------------------
Write-Step 'Step 4 . Removing application files'

if (Test-Path $InstallPath) {
    Remove-Item $InstallPath -Recurse -Force
    Write-Ok "Removed: $InstallPath"
} else {
    Write-Skip "Install path not found: $InstallPath"
}

# -- 5. Certificate (optional) ------------------------------------------------
Write-Step 'Step 5 . Certificate'

if ($RemoveCertificate) {
    if ($boundThumbprint) {
        $cert = Get-Item "Cert:\LocalMachine\My\$boundThumbprint" -ErrorAction SilentlyContinue
        if ($cert -and $cert.Subject -eq "CN=$env:COMPUTERNAME" -and $cert.Issuer -eq "CN=$env:COMPUTERNAME") {
            Remove-Item "Cert:\LocalMachine\My\$boundThumbprint" -Force
            Write-Ok "Self-signed certificate removed: $boundThumbprint"
        } elseif ($cert) {
            Write-Warn "Certificate $boundThumbprint is CA-issued ($($cert.Subject)) - skipping removal."
        } else {
            Write-Skip "Certificate $boundThumbprint no longer in store."
        }
    } else {
        Write-Skip 'No HTTP.sys-bound certificate thumbprint found to remove.'
    }
} else {
    Write-Skip 'Certificate left in place (-RemoveCertificate not specified).'
}

# -- 6. Service account (optional) -------------------------------------------
Write-Step 'Step 6 . Service account'

if ($RemoveServiceAccount) {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$SvcAccountName'" -ErrorAction SilentlyContinue
        if ($adUser) {
            Remove-ADUser -Identity $adUser -Confirm:$false
            Write-Ok "AD account removed: $SvcAccountName"
        } else {
            Write-Skip "AD account not found: $SvcAccountName"
        }
    } catch {
        Write-Warn "Could not remove AD account: $_"
    }
} else {
    Write-Skip "Service account left in place (-RemoveServiceAccount not specified)."
}

# -- Done ---------------------------------------------------------------------
Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host '  |       Uninstall Complete                             |' -ForegroundColor Green
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host ''
