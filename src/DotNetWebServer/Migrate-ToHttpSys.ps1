#Requires -Version 5.1
<#
.SYNOPSIS
    One-time migration script: switches the running OsmUserWeb service from the
    Kestrel/EphemeralKeySet approach to HTTP.sys, cleans up duplicate certs, and
    registers the necessary netsh URL ACL and SSL cert bindings.

.PARAMETER PublishPath
    Path to the updated dotnet publish output (the folder containing OsmUserWeb.exe
    built after the HTTP.sys switch).  Prompted if omitted.

.PARAMETER InstallPath
    Service installation directory.  Default: C:\Services\OsmUserWeb

.PARAMETER CertThumbprint
    Thumbprint of the certificate to register with HTTP.sys.
    If omitted the script auto-selects the newest CN=AC-WINADMIN cert in
    Cert:\LocalMachine\My and removes the older duplicates.

.PARAMETER HttpsPort
    HTTPS port.  Default: 8443

.EXAMPLE
    .\Migrate-ToHttpSys.ps1 -PublishPath C:\temp\publish
#>
[CmdletBinding()]
param(
    [string]$PublishPath,
    [string]$InstallPath    = 'C:\Services\OsmUserWeb',
    [string]$CertThumbprint,
    [int]   $HttpsPort      = 8443
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'OsmUserWeb'

function Write-Step { param([string]$Msg) Write-Host "`n  >> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

# ==============================================================================

Write-Host "`n  +======================================================+" -ForegroundColor Cyan
Write-Host "  |       OsmUserWeb - HTTP.sys Migration               |" -ForegroundColor Cyan
Write-Host "  +======================================================+`n" -ForegroundColor Cyan

# -- 0. Admin check -----------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as Administrator.'
}

# -- 1. Publish path ----------------------------------------------------------
Write-Step 'Step 1 . Locating publish output'

if (-not $PublishPath) {
    $PublishPath = (Read-Host 'Path to dotnet publish output (folder containing OsmUserWeb.exe)').Trim()
}
$PublishPath = (Resolve-Path $PublishPath).Path
if (-not (Test-Path (Join-Path $PublishPath 'OsmUserWeb.exe'))) {
    throw "OsmUserWeb.exe not found in: $PublishPath"
}
Write-Ok "Publish source: $PublishPath"

# -- 2. Stop service ----------------------------------------------------------
Write-Step 'Step 2 . Stopping service'

$svcState = (& sc.exe query $ServiceName) -join ''
if ($svcState -match 'STATE.*4.*RUNNING') {
    & sc.exe stop $ServiceName | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    do { Start-Sleep -Milliseconds 500
    } while ((& sc.exe query $ServiceName) -join '' -match 'STATE.*4.*RUNNING' -and (Get-Date) -lt $deadline)
    Write-Ok 'Service stopped.'
} else {
    Write-Ok 'Service was not running.'
}

# -- 3. Deploy new binaries ---------------------------------------------------
Write-Step 'Step 3 . Deploying binaries'

$resolvedPublish = $PublishPath.TrimEnd('\')
$resolvedInstall = $InstallPath.TrimEnd('\')

if ($resolvedPublish -eq $resolvedInstall) {
    Write-Ok 'Publish path is the install path - skipping copy.'
} else {
    # Preserve the live appsettings.Production.json; overwrite everything else.
    Get-ChildItem $PublishPath |
        Where-Object Name -ne 'appsettings.Production.json' |
        ForEach-Object { Copy-Item $_.FullName -Destination $InstallPath -Recurse -Force }
    Write-Ok "Binaries deployed to $InstallPath"
}

# -- 4. Certificate selection and duplicate cleanup ---------------------------
Write-Step 'Step 4 . Certificate selection and cleanup'

$acwCerts = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq 'CN=AC-WINADMIN' } |
    Sort-Object NotBefore -Descending

if (-not $CertThumbprint) {
    if ($acwCerts.Count -eq 0) {
        throw "No CN=AC-WINADMIN certificate in LocalMachine\My. Pass -CertThumbprint explicitly."
    }
    $activeCert      = $acwCerts[0]
    $CertThumbprint  = $activeCert.Thumbprint
    Write-Ok "Auto-selected newest CN=AC-WINADMIN: $CertThumbprint (expires $($activeCert.NotAfter.ToString('yyyy-MM-dd')))"
} else {
    $activeCert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction Stop
    Write-Ok "Using specified cert: $CertThumbprint ($($activeCert.Subject), expires $($activeCert.NotAfter.ToString('yyyy-MM-dd')))"
}

# Remove older CN=AC-WINADMIN duplicates
$removed = 0
foreach ($old in ($acwCerts | Where-Object Thumbprint -ne $CertThumbprint)) {
    Remove-Item "Cert:\LocalMachine\My\$($old.Thumbprint)" -Force
    Write-Ok "Removed stale cert: $($old.Thumbprint) (created $($old.NotBefore.ToString('yyyy-MM-dd')))"
    $removed++
}
if ($removed -eq 0) { Write-Ok 'No duplicate certs to remove.' }

# -- 5. HTTP.sys URL ACL and SSL cert binding ---------------------------------
Write-Step "Step 5 . Registering HTTP.sys (port $HttpsPort)"

# Resolve the service account name from the SCM registration
$svcAccount = (Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop).StartName
Write-Ok "Service account: $svcAccount"

# URL ACL - grants svc-osmweb permission to accept connections on the HTTPS port
& netsh http delete urlacl "url=https://+:$HttpsPort/" 2>$null | Out-Null
$urlOut = & netsh http add urlacl "url=https://+:$HttpsPort/" "user=$svcAccount" 2>&1
if ($LASTEXITCODE -eq 0) { Write-Ok "URL ACL: https://+:$HttpsPort/ granted to $svcAccount" }
else { Write-Warn "URL ACL failed (exit $LASTEXITCODE): $urlOut" }

# SSL cert binding - HTTP.sys uses this to perform TLS (kernel mode, no key access by svc-osmweb)
$appId = "{$([System.Guid]::NewGuid().ToString())}"
foreach ($ip in @('0.0.0.0', '[::]')) {
    & netsh http delete sslcert "ipport=${ip}:$HttpsPort" 2>$null | Out-Null
    $sslOut = & netsh http add sslcert "ipport=${ip}:$HttpsPort" `
                  "certhash=$CertThumbprint" "appid=$appId" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok "SSL cert bound: ${ip}:$HttpsPort -> $CertThumbprint" }
    else { Write-Warn "SSL cert ${ip} failed (exit $LASTEXITCODE): $sslOut" }
}

# -- 6. Update appsettings.Production.json ------------------------------------
Write-Step 'Step 6 . Updating appsettings.Production.json'

$configPath = Join-Path $InstallPath 'appsettings.Production.json'
$existing   = Get-Content $configPath -Raw | ConvertFrom-Json

$configObj = [ordered]@{
    Logging    = [ordered]@{
        LogLevel = [ordered]@{
            Default                = 'Warning'
            OsmUserWeb             = 'Information'
            'Microsoft.AspNetCore' = 'Warning'
        }
        EventLog = [ordered]@{ SourceName = 'OsmUserWeb'; LogName = 'Application' }
    }
    AdSettings = [ordered]@{
        TargetOU  = $existing.AdSettings.TargetOU
        GroupName = $existing.AdSettings.GroupName
    }
}

$configObj | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
Write-Ok 'Kestrel and TlsCertificate sections removed; only Logging + AdSettings remain.'

# -- 7. Update service registry environment -----------------------------------
Write-Step 'Step 7 . Updating service registry environment'

$regPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$existEnv = (Get-ItemProperty $regPath -ErrorAction Stop).Environment

# Preserve AdSettings__DefaultPassword
$existingPw = ($existEnv | Where-Object { $_ -like 'AdSettings__DefaultPassword=*' }) `
              -replace '^AdSettings__DefaultPassword=', ''
if (-not $existingPw) {
    $existingPw = Read-Host 'AdSettings__DefaultPassword not found in registry - enter it now'
}

$urls = "http://localhost:5150;https://+:$HttpsPort"
Set-ItemProperty $regPath -Name Environment -Value @(
    'ASPNETCORE_ENVIRONMENT=Production',
    "AdSettings__DefaultPassword=$existingPw",
    "ASPNETCORE_URLS=$urls"
)
Write-Ok "Registry env updated."
Write-Ok "ASPNETCORE_URLS=$urls"

# -- 8. Start service and verify ----------------------------------------------
Write-Step 'Step 8 . Starting service'

& sc.exe start $ServiceName | Out-Null

$running  = $false
$deadline = (Get-Date).AddSeconds(20)
do {
    Start-Sleep -Milliseconds 600
    if ((& sc.exe query $ServiceName) -join '' -match 'STATE.*4.*RUNNING') {
        $running = $true; break
    }
} while ((Get-Date) -lt $deadline)

if ($running) {
    Write-Ok 'Service reached RUNNING state.'
    Start-Sleep -Seconds 2

    # Connectivity test
    $curlOut = & curl.exe -k -s -o $null -w '%{http_code}' "https://localhost:$HttpsPort/" 2>&1
    if ($curlOut -eq '200') {
        Write-Ok "HTTPS responding: https://localhost:$HttpsPort/ -> HTTP 200"
    } else {
        Write-Warn "curl returned: $curlOut (self-signed cert warnings are normal; try from a browser)"
    }
} else {
    Write-Fail 'Service did not reach RUNNING within 20 seconds.'
    Write-Host "`n  Recent event log entries:" -ForegroundColor Yellow
    Get-EventLog -LogName Application -Source $ServiceName -Newest 5 -ErrorAction SilentlyContinue |
        Select-Object TimeGenerated, EntryType, Message | Format-List
    Get-EventLog -LogName System -Source 'HTTP' -Newest 5 -ErrorAction SilentlyContinue |
        Select-Object TimeGenerated, EntryType, Message | Format-List
}

# -- Summary ------------------------------------------------------------------
Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host '  |       Migration Complete                             |' -ForegroundColor Green
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host "  |  Service   : $ServiceName"                              -ForegroundColor Green
Write-Host "  |  Cert      : $CertThumbprint"                          -ForegroundColor Green
Write-Host "  |  URL       : https://$env:COMPUTERNAME`:$HttpsPort/"   -ForegroundColor Green
Write-Host '  |'                                                        -ForegroundColor Green
Write-Host '  |  In your browser (accept the self-signed cert warning):' -ForegroundColor Green
Write-Host "  |    https://$env:COMPUTERNAME`:$HttpsPort/"             -ForegroundColor Green
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host ''
