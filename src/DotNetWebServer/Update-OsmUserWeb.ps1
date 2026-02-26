#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys a new build of OsmUserWeb to an already-configured server.

.DESCRIPTION
    Performs a safe in-place binary update without touching the live production
    configuration or re-prompting for secrets.  All persistent state on the server
    (appsettings.Production.json, service account, HTTP.sys bindings, firewall
    rules, registry secrets) is preserved.

    Steps:
      1.  Verify prerequisites (admin, service exists)
      2.  Locate and validate the new publish output
      3.  Stop the running service
      4.  Copy new binaries, preserving appsettings.Production.json
      5.  Remove stale self-signed certificate duplicates from LocalMachine\My
      6.  Re-register HTTP.sys URL ACL and SSL cert binding
             (service account and port are read from the SCM / registry —
              no re-entry of credentials needed)
      7.  Start the service and verify HTTPS connectivity with curl

.PARAMETER PublishPath
    Path to the dotnet publish output folder (must contain OsmUserWeb.exe).
    Prompted interactively if omitted.

.PARAMETER InstallPath
    Service installation directory on this server.  Default: C:\Services\OsmUserWeb

.PARAMETER ServiceName
    Windows Service name.  Default: OsmUserWeb

.PARAMETER HttpsPort
    HTTPS port.  Default: read from the service registry environment; falls back
    to 8443 if the registry entry is absent.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    # Interactive — prompts for publish path, shows summary before proceeding
    .\Update-OsmUserWeb.ps1

.EXAMPLE
    # Fully non-interactive (CI / scripted deployment)
    .\Update-OsmUserWeb.ps1 -PublishPath .\app -Force

.EXAMPLE
    # Remote execution via Invoke-Command (called from Update-OsmUserWeb-Remote.ps1)
    .\Update-OsmUserWeb.ps1 -PublishPath C:\Windows\Temp\OsmUpdate\app -Force
#>
[CmdletBinding()]
param(
    [string]$PublishPath,
    [string]$InstallPath  = 'C:\Services\OsmUserWeb',
    [string]$ServiceName  = 'OsmUserWeb',
    [int]   $HttpsPort    = 0,        # 0 = auto-detect from registry
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogTranscript = Join-Path $env:TEMP "Update-OsmUserWeb-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Step { param([string]$Msg) Write-Host "`n  >> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green  }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }

# ==============================================================================

Start-Transcript -Path $LogTranscript -Force | Out-Null

Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host '  |       OsmUserWeb - Update                            |' -ForegroundColor Cyan
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host "  Log: $LogTranscript" -ForegroundColor DarkGray
Write-Host ''

try {

    # -- Step 1: Prerequisites ------------------------------------------------
    Write-Step 'Step 1 . Checking prerequisites'

    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator.'
    }
    Write-Ok 'Running as Administrator.'

    $svcQuery = & sc.exe query $ServiceName 2>$null
    if ($svcQuery -join '' -notmatch 'SERVICE_NAME') {
        throw "Service '$ServiceName' is not registered on this machine. Run Install-OsmUserWeb.ps1 first."
    }
    Write-Ok "Service '$ServiceName' is registered."

    # -- Step 2: Resolve publish path -----------------------------------------
    Write-Step 'Step 2 . Locating publish output'

    if (-not $PublishPath) {
        do { $PublishPath = (Read-Host 'Path to dotnet publish output (folder containing OsmUserWeb.exe)').Trim()
        } while ([string]::IsNullOrWhiteSpace($PublishPath))
    }
    $PublishPath = (Resolve-Path $PublishPath -ErrorAction Stop).Path
    if (-not (Test-Path (Join-Path $PublishPath 'OsmUserWeb.exe'))) {
        throw "OsmUserWeb.exe not found in '$PublishPath'. Run dotnet publish first."
    }
    $exeVer = [System.Diagnostics.FileVersionInfo]::GetVersionInfo(
                  (Join-Path $PublishPath 'OsmUserWeb.exe')).FileVersion
    Write-Ok "Publish source verified: $PublishPath"
    Write-Ok "New binary version: $exeVer"

    # -- Step 3: Read live config from SCM / registry -------------------------
    Write-Step 'Step 3 . Reading live configuration from SCM and registry'

    $svcAccount = (Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" `
                       -ErrorAction Stop).StartName
    Write-Ok "Service account: $svcAccount"

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if ($HttpsPort -eq 0) {
        $regEnv   = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).Environment
        $urlsLine = $regEnv | Where-Object { $_ -like 'ASPNETCORE_URLS=*' }
        if ($urlsLine -and $urlsLine -match 'https://\+:(\d+)') {
            $HttpsPort = [int]$Matches[1]
            Write-Ok "HTTPS port from registry: $HttpsPort"
        } else {
            $HttpsPort = 8443
            Write-Warn "ASPNETCORE_URLS not found in registry — defaulting to port $HttpsPort"
        }
    } else {
        Write-Ok "HTTPS port (supplied): $HttpsPort"
    }

    # Resolve the active cert thumbprint from the HTTP.sys binding so we can
    # re-register it after the binary swap without asking for the PFX again.
    $sslInfo      = & netsh http show sslcert "ipport=0.0.0.0:$HttpsPort" 2>$null
    $certThumbprint = $null
    if ($sslInfo -match 'Certificate Hash\s+:\s+([0-9A-Fa-f]{40})') {
        $certThumbprint = $Matches[1].ToUpper()
        Write-Ok "Active certificate thumbprint: $certThumbprint"
    } else {
        Write-Warn "No HTTP.sys sslcert binding found for port $HttpsPort — TLS will not be re-registered."
    }

    # -- Confirmation ----------------------------------------------------------
    $installedVer = $null
    $installedExe = Join-Path $InstallPath 'OsmUserWeb.exe'
    if (Test-Path $installedExe) {
        $installedVer = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($installedExe).FileVersion
    }

    Write-Host ''
    Write-Host '  -- Update summary ------------------------------------------' -ForegroundColor DarkGray
    Write-Host "  Install path    : $InstallPath"
    Write-Host "  Service account : $svcAccount"
    Write-Host "  HTTPS port      : $HttpsPort"
    if ($installedVer) { Write-Host "  Current version : $installedVer" }
    Write-Host "  New version     : $exeVer"
    Write-Host ''

    if (-not $Force) {
        $go = Read-Host '  Proceed with update? (Y/N)'
        if ($go -notin 'Y', 'y') {
            Write-Host 'Aborted. No changes were made.' -ForegroundColor Yellow
            exit 0
        }
    }

    # -- Step 4: Stop service -------------------------------------------------
    Write-Step 'Step 4 . Stopping service'

    if ($svcQuery -join '' -match 'STATE\s+:\s+4\s+RUNNING') {
        $svcProcess = Get-Process -Name $ServiceName -ErrorAction SilentlyContinue
        & sc.exe stop $ServiceName 2>$null | Out-Null

        $deadline = (Get-Date).AddSeconds(20)
        do { Start-Sleep -Milliseconds 500
        } while ((& sc.exe query $ServiceName) -join '' -notmatch 'STATE\s+:\s+1\s+STOPPED' `
                 -and (Get-Date) -lt $deadline)

        if ($svcProcess -and -not $svcProcess.HasExited) {
            $null = $svcProcess.WaitForExit(8000)
        }
        Write-Ok 'Service stopped.'
    } else {
        Write-Skip 'Service was not running.'
    }

    # -- Step 5: Deploy binaries (preserve production config) -----------------
    Write-Step 'Step 5 . Deploying new binaries'

    $resolvedPublish = $PublishPath.TrimEnd('\')
    $resolvedInstall = $InstallPath.TrimEnd('\')

    if ($resolvedPublish -eq $resolvedInstall) {
        Write-Skip 'Publish path is the install path — no copy needed.'
    } else {
        # Copy everything except the live production config so that all
        # appsettings, secrets, and OU/group configuration are preserved.
        Get-ChildItem $PublishPath |
            Where-Object { $_.Name -ne 'appsettings.Production.json' } |
            ForEach-Object { Copy-Item $_.FullName -Destination $InstallPath -Recurse -Force }
        Write-Ok "Binaries deployed to $InstallPath (appsettings.Production.json preserved)."
    }

    # -- Step 6: Self-signed certificate duplicate cleanup --------------------
    Write-Step 'Step 6 . Self-signed certificate cleanup'

    # Only relevant when the active cert is self-signed (Subject == Issuer == CN=<hostname>).
    if ($certThumbprint) {
        $activeCert = Get-Item "Cert:\LocalMachine\My\$certThumbprint" -ErrorAction SilentlyContinue
        $isSelfSigned = $activeCert -and
                        $activeCert.Subject -eq "CN=$env:COMPUTERNAME" -and
                        $activeCert.Issuer  -eq "CN=$env:COMPUTERNAME"

        if ($isSelfSigned) {
            $staleCerts = Get-ChildItem 'Cert:\LocalMachine\My' |
                Where-Object {
                    $_.Subject    -eq "CN=$env:COMPUTERNAME" -and
                    $_.Issuer     -eq "CN=$env:COMPUTERNAME" -and
                    $_.Thumbprint -ne $certThumbprint
                }

            if ($staleCerts) {
                foreach ($stale in $staleCerts) {
                    Remove-Item "Cert:\LocalMachine\My\$($stale.Thumbprint)" -Force
                    Write-Ok "Removed stale self-signed cert: $($stale.Thumbprint) (created $($stale.NotBefore.ToString('yyyy-MM-dd')))"
                }
            } else {
                Write-Skip 'No stale self-signed certificate duplicates found.'
            }
        } else {
            Write-Skip 'Active certificate is CA-issued — duplicate cleanup skipped.'
        }
    } else {
        Write-Skip 'No active certificate found — cleanup skipped.'
    }

    # -- Step 7: Re-register HTTP.sys URL ACL and SSL cert binding ------------
    Write-Step "Step 7 . Re-registering HTTP.sys (port $HttpsPort)"

    & netsh http delete urlacl "url=https://+:$HttpsPort/" 2>$null | Out-Null
    $urlOut = & netsh http add urlacl "url=https://+:$HttpsPort/" "user=$svcAccount" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "URL ACL registered: https://+:$HttpsPort/ -> $svcAccount"
    } else {
        Write-Warn "URL ACL registration failed (exit $LASTEXITCODE): $urlOut"
    }

    if ($certThumbprint) {
        $appId = "{$([System.Guid]::NewGuid().ToString())}"
        foreach ($ip in @('0.0.0.0', '[::]')) {
            & netsh http delete sslcert "ipport=${ip}:$HttpsPort" 2>$null | Out-Null
            $sslOut = & netsh http add sslcert "ipport=${ip}:$HttpsPort" `
                          "certhash=$certThumbprint" "appid=$appId" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "SSL cert binding registered: ${ip}:$HttpsPort -> $certThumbprint"
            } else {
                Write-Warn "SSL cert binding failed for ${ip} (exit $LASTEXITCODE): $sslOut"
            }
        }
    } else {
        Write-Skip 'No certificate thumbprint — SSL cert binding skipped.'
    }

    # -- Step 8: Start service and verify -------------------------------------
    Write-Step 'Step 8 . Starting service'

    & sc.exe start $ServiceName | Out-Null

    $running  = $false
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 600
        if ((& sc.exe query $ServiceName) -join '' -match 'STATE\s+:\s+4\s+RUNNING') {
            $running = $true; break
        }
    } while ((Get-Date) -lt $deadline)

    if ($running) {
        Write-Ok 'Service reached RUNNING state.'
        Start-Sleep -Seconds 3

        if ($certThumbprint) {
            $curlOut = & curl.exe -k -s -o $null -w '%{http_code}' `
                           "https://localhost:$HttpsPort/" 2>&1
            if ($curlOut -eq '200') {
                Write-Ok "HTTPS connectivity verified: https://localhost:$HttpsPort/ -> HTTP 200"
            } else {
                Write-Warn "HTTPS check returned: '$curlOut' — service started but port $HttpsPort is not responding."
                Write-Host ''
                Write-Host '  Recent application event log entries:' -ForegroundColor Yellow
                Get-EventLog -LogName Application -Source $ServiceName -Newest 10 `
                    -ErrorAction SilentlyContinue |
                    Select-Object TimeGenerated, EntryType, Message | Format-List
            }
        }
    } else {
        Write-Warn 'Service did not reach RUNNING within 30 seconds.'
        Write-Host ''
        Write-Host '  Recent application event log entries:' -ForegroundColor Yellow
        Get-EventLog -LogName Application -Source $ServiceName -Newest 10 `
            -ErrorAction SilentlyContinue |
            Select-Object TimeGenerated, EntryType, Message | Format-List
    }

    # -- Summary ---------------------------------------------------------------
    Write-Host ''
    Write-Host '  +======================================================+' -ForegroundColor Green
    Write-Host '  |       Update Complete                                 |' -ForegroundColor Green
    Write-Host '  +======================================================+' -ForegroundColor Green
    Write-Host "  |  Service   : $ServiceName"                              -ForegroundColor Green
    Write-Host "  |  Version   : $exeVer"                                   -ForegroundColor Green
    Write-Host "  |  URL       : https://$env:COMPUTERNAME`:$HttpsPort/"    -ForegroundColor Green
    Write-Host '  +======================================================+' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Full update log: $LogTranscript" -ForegroundColor DarkGray
    Write-Host ''

} catch {
    Write-Host ''
    Write-Host "    [FAIL] Update failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "           At: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    Write-Host "`n  Full update log: $LogTranscript" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
