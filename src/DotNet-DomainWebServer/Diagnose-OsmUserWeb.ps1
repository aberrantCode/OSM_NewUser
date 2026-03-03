#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses a connection-refused / not-responding OsmUserWeb installation.

.DESCRIPTION
    Checks every layer between the installer completing and a browser reaching
    the service: SCM state, port listening status, HTTP.sys URL ACL and SSL cert
    bindings, Windows Firewall rules, application / HTTP.sys event log entries,
    and a local curl connectivity probe.

.PARAMETER ServiceName
    Windows Service name.  Default: OsmUserWeb

.PARAMETER HttpsPort
    HTTPS port to test.  Default: read from the service registry; falls back to 8443.

.PARAMETER InstallPath
    Service installation directory.  Default: C:\Services\OsmUserWeb

.EXAMPLE
    .\Diagnose-OsmUserWeb.ps1

.EXAMPLE
    .\Diagnose-OsmUserWeb.ps1 -HttpsPort 443
#>
[CmdletBinding()]
param(
    [string]$ServiceName  = 'OsmUserWeb',
    [int]   $HttpsPort    = 0,            # 0 = auto-detect from registry
    [string]$InstallPath  = 'C:\Services\OsmUserWeb'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # keep going even if individual checks fail

$LogTranscript    = Join-Path $env:TEMP "Diagnose-OsmUserWeb-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:issueDetected = $false   # set to $true by Write-Warn / Write-Fail
Start-Transcript -Path $LogTranscript -Force | Out-Null

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Header ([string]$Title) {
    $bar = '=' * 56
    Write-Host ''
    Write-Host "  $bar"  -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $bar"  -ForegroundColor Cyan
}

function Write-Check ([string]$Label) {
    Write-Host "`n  -- $Label" -ForegroundColor DarkGray
}

function Write-Ok   ([string]$Msg) { Write-Host "    [OK]    $Msg" -ForegroundColor Green  }
function Write-Warn ([string]$Msg) { $script:issueDetected = $true; Write-Host "    [WARN]  $Msg" -ForegroundColor Yellow }
function Write-Fail ([string]$Msg) { $script:issueDetected = $true; Write-Host "    [FAIL]  $Msg" -ForegroundColor Red    }
function Write-Info ([string]$Msg) { Write-Host "    [INFO]  $Msg" -ForegroundColor White  }

# ── Banner ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host '  |       OsmUserWeb - Diagnostics                       |' -ForegroundColor Cyan
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host "  Machine : $env:COMPUTERNAME"
Write-Host "  Time    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "  Log     : $LogTranscript" -ForegroundColor DarkGray
Write-Host ''

# ── 0. Admin check ─────────────────────────────────────────────────────────────

Write-Header 'Section 0 . Administrator check'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Ok  'Running as Administrator.'
} else {
    Write-Fail 'NOT running as Administrator. Some checks will be incomplete.'
    Write-Warn 'Re-run from an elevated PowerShell prompt for full results.'
}

# ── 1. Discover port ───────────────────────────────────────────────────────────

Write-Header 'Section 1 . Port discovery'

$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
if ($HttpsPort -eq 0) {
    if (Test-Path $regPath) {
        $regEnv   = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).Environment
        $urlsLine = $regEnv | Where-Object { $_ -like 'ASPNETCORE_URLS=*' }
        if ($urlsLine -and $urlsLine -match 'https://\+:(\d+)') {
            $HttpsPort = [int]$Matches[1]
            Write-Ok  "Detected HTTPS port from registry: $HttpsPort"
            Write-Info "ASPNETCORE_URLS = $($urlsLine -replace '^ASPNETCORE_URLS=','')"
        } else {
            $HttpsPort = 8443
            Write-Warn "ASPNETCORE_URLS not found in registry — defaulting to port $HttpsPort"
            if ($urlsLine) { Write-Info "Found: $urlsLine" }
            else            { Write-Info 'No ASPNETCORE_URLS entry present.' }
        }
    } else {
        $HttpsPort = 8443
        Write-Warn "Service registry key not found: $regPath"
        Write-Warn "Defaulting to port $HttpsPort — is the service registered?"
    }
} else {
    Write-Info "Using -HttpsPort $HttpsPort (supplied on command line)."
}

# ── 2. Service state ───────────────────────────────────────────────────────────

Write-Header 'Section 2 . Windows Service state'
Write-Check 'sc.exe query'

$scOutput = & sc.exe query $ServiceName 2>&1
if ($scOutput -join '' -match 'SERVICE_NAME') {
    Write-Host ($scOutput | Where-Object { $_ -match 'STATE|TYPE|PID' }) -ForegroundColor White
    if ($scOutput -join '' -match 'STATE\s+:\s+4\s+RUNNING') {
        Write-Ok  'Service is RUNNING.'
    } elseif ($scOutput -join '' -match 'STATE\s+:\s+1\s+STOPPED') {
        Write-Fail 'Service is STOPPED.  It may have crashed — see Section 6 (event log).'
    } else {
        Write-Warn "Service is in an unexpected state:`n$($scOutput -join "`n")"
    }
} else {
    Write-Fail "Service '$ServiceName' not found.  Has it been installed?"
}

# ── 3. Port listening ──────────────────────────────────────────────────────────

Write-Header "Section 3 . TCP port $HttpsPort (netstat)"
Write-Check 'netstat -ano'

$netstatLines = & netstat -ano 2>&1 | Where-Object { $_ -match ":$HttpsPort\s" }
if ($netstatLines) {
    $netstatLines | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
    if ($netstatLines | Where-Object { $_ -match 'LISTENING' }) {
        Write-Ok  "Port $HttpsPort is LISTENING."
    } else {
        Write-Warn "Port $HttpsPort appears in netstat but is not in LISTENING state."
    }
} else {
    Write-Fail "Nothing is listening on port $HttpsPort."
    Write-Warn 'HTTP.sys never opened the port — the service likely crashed before app.Run() completed.'
}

# ── 4. HTTP.sys URL ACL ────────────────────────────────────────────────────────

Write-Header 'Section 4 . HTTP.sys URL ACL'
Write-Check "netsh http show urlacl url=https://+:$HttpsPort/"

$urlAcl = & netsh http show urlacl "url=https://+:$HttpsPort/" 2>&1
if ($urlAcl -match 'Reserved URL') {
    Write-Ok  "URL ACL exists for https://+:$HttpsPort/"
    $urlAcl | Where-Object { $_ -match 'User:|SDDL' } |
        ForEach-Object { Write-Info $_.Trim() }
} else {
    Write-Fail "No URL ACL found for https://+:$HttpsPort/"
    Write-Warn 'Run: netsh http add urlacl url="https://+:' + $HttpsPort + '/" user="DOMAIN\svc-osmweb"'
}

# ── 5. HTTP.sys SSL cert binding ───────────────────────────────────────────────

Write-Header 'Section 5 . HTTP.sys SSL cert binding'

foreach ($ip in @('0.0.0.0', '[::]')) {
    Write-Check "netsh http show sslcert ipport=${ip}:$HttpsPort"
    $sslShow = & netsh http show sslcert "ipport=${ip}:$HttpsPort" 2>&1
    if ($sslShow -match 'Certificate Hash') {
        Write-Ok  "SSL cert binding present: ${ip}:$HttpsPort"
        $sslShow | Where-Object { $_ -match 'Hash|Application ID|Store Name' } |
            ForEach-Object { Write-Info $_.Trim() }
    } else {
        Write-Fail "No SSL cert binding found: ${ip}:$HttpsPort"
        Write-Warn "Run: netsh http add sslcert ipport=${ip}:$HttpsPort certhash=<thumbprint> appid={<guid>}"
    }
}

# ── 6. Certificate in LocalMachine\My ─────────────────────────────────────────

Write-Header 'Section 6 . Certificate store'
Write-Check 'Cert:\LocalMachine\My'

# Try to get the thumbprint from the sslcert binding
$sslInfo = & netsh http show sslcert "ipport=0.0.0.0:$HttpsPort" 2>&1
$thumbprint = $null
if ($sslInfo -match 'Certificate Hash\s+:\s+([0-9A-Fa-f]{40})') {
    $thumbprint = $Matches[1].ToUpper()
    $cert = Get-Item "Cert:\LocalMachine\My\$thumbprint" -ErrorAction SilentlyContinue
    if ($cert) {
        Write-Ok  "Certificate found in LocalMachine\My"
        Write-Info "Thumbprint : $thumbprint"
        Write-Info "Subject    : $($cert.Subject)"
        Write-Info "Issuer     : $($cert.Issuer)"
        Write-Info "Expires    : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
        Write-Info "HasPrivKey : $($cert.HasPrivateKey)"
        if ($cert.NotAfter -lt (Get-Date)) {
            Write-Fail 'Certificate has EXPIRED.'
        } elseif ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
            Write-Warn 'Certificate expires within 30 days.'
        }
        if (-not $cert.HasPrivateKey) {
            Write-Fail 'Certificate has no private key — HTTP.sys cannot perform TLS.'
        }
    } else {
        Write-Fail "Certificate $thumbprint referenced by sslcert binding but NOT found in LocalMachine\My"
    }
} else {
    Write-Warn 'Cannot check certificate — no sslcert binding found (see Section 5).'
}

# ── 7. Windows Firewall ────────────────────────────────────────────────────────

Write-Header 'Section 7 . Windows Firewall'
Write-Check 'OsmUserWeb firewall rules'

$fwRules = Get-NetFirewallRule -DisplayName 'OsmUserWeb*' -ErrorAction SilentlyContinue
if ($fwRules) {
    foreach ($rule in $fwRules) {
        $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $addrFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
        $status = if ($rule.Action -eq 'Allow') { 'ALLOW' } else { 'BLOCK' }
        Write-Info "[$status] $($rule.DisplayName)"
        if ($portFilter) { Write-Info "       Ports : $($portFilter.LocalPort)" }
        if ($addrFilter) { Write-Info "       From  : $($addrFilter.RemoteAddress)" }
    }
    Write-Ok "Found $($fwRules.Count) OsmUserWeb firewall rule(s)."
} else {
    Write-Warn 'No OsmUserWeb firewall rules found.'
    Write-Warn "Port $HttpsPort may be reachable from everywhere, or blocked by a default deny rule."
}

Write-Check "Windows Firewall profile status"
try {
    Get-NetFirewallProfile | Select-Object Name, Enabled |
        ForEach-Object { Write-Info "$($_.Name): Enabled=$($_.Enabled)" }
} catch {
    Write-Warn "Could not query firewall profiles: $_"
}

# ── 8. Application event log ──────────────────────────────────────────────────

Write-Header 'Section 8 . Application event log (OsmUserWeb source)'

$appEvents = Get-EventLog -LogName Application -Source $ServiceName `
    -Newest 20 -ErrorAction SilentlyContinue

if ($appEvents) {
    foreach ($ev in $appEvents) {
        $level = switch ($ev.EntryType) {
            'Error'   { 'FAIL '; break }
            'Warning' { 'WARN '; break }
            default   { 'INFO ' }
        }
        $color = switch ($ev.EntryType) {
            'Error'   { 'Red'; break }
            'Warning' { 'Yellow'; break }
            default   { 'White' }
        }
        $time = $ev.TimeGenerated.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Host "    [$level $time] $($ev.Message.Split("`n")[0])" -ForegroundColor $color
    }
} else {
    Write-Warn "No event log entries found for source '$ServiceName'."
    Write-Info 'If the service crashes before the EventLog sink initialises, entries appear under .NET Runtime instead.'
}

# ── 9. .NET Runtime event log ──────────────────────────────────────────────────

Write-Header 'Section 9 . Application event log (.NET Runtime / Application Error)'

foreach ($src in @('.NET Runtime', 'Application Error', 'Windows Error Reporting')) {
    $dotnetEvents = Get-EventLog -LogName Application -Source $src `
        -Newest 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'OsmUserWeb|dotnet' }
    if ($dotnetEvents) {
        Write-Check "Source: $src"
        foreach ($ev in $dotnetEvents) {
            $time = $ev.TimeGenerated.ToString('yyyy-MM-dd HH:mm:ss')
            Write-Host "    [$($ev.EntryType.ToString().ToUpper()) $time]" -ForegroundColor Red
            # Print first 8 lines of the message
            $ev.Message.Split("`n") | Select-Object -First 8 |
                ForEach-Object { Write-Host "      $_" -ForegroundColor White }
        }
    }
}

# ── 10. HTTP.sys / System event log ───────────────────────────────────────────

Write-Header 'Section 10 . System event log (HTTP source)'

$httpEvents = Get-EventLog -LogName System -Source 'HTTP' `
    -Newest 10 -ErrorAction SilentlyContinue
if ($httpEvents) {
    foreach ($ev in $httpEvents) {
        $time = $ev.TimeGenerated.ToString('yyyy-MM-dd HH:mm:ss')
        $color = if ($ev.EntryType -eq 'Error') { 'Red' } else { 'White' }
        Write-Host "    [$($ev.EntryType.ToString().ToUpper()) $time] $($ev.Message.Split("`n")[0])" `
            -ForegroundColor $color
    }
} else {
    Write-Info 'No HTTP source entries in the System event log.'
}

# ── 11. Install directory ──────────────────────────────────────────────────────

Write-Header 'Section 11 . Install directory'
Write-Check $InstallPath

if (Test-Path $InstallPath) {
    Write-Ok  "Directory exists: $InstallPath"
    $exe = Join-Path $InstallPath 'OsmUserWeb.exe'
    if (Test-Path $exe) {
        $fi = [System.IO.FileInfo]$exe
        Write-Ok  "OsmUserWeb.exe found ($([math]::Round($fi.Length/1KB)) KB)"
        try {
            $fv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
            Write-Info "Version: $($fv.FileVersion)  Product: $($fv.ProductVersion)"
        } catch {}
    } else {
        Write-Fail "OsmUserWeb.exe NOT found in $InstallPath"
    }
    $cfg = Join-Path $InstallPath 'appsettings.Production.json'
    if (Test-Path $cfg) {
        Write-Ok  'appsettings.Production.json present.'
        try {
            $json = Get-Content $cfg -Raw | ConvertFrom-Json
            Write-Info "AdSettings.TargetOU  : $($json.AdSettings.TargetOU)"
            Write-Info "AdSettings.GroupName : $($json.AdSettings.GroupName)"
        } catch { Write-Warn "Could not parse config: $_" }
    } else {
        Write-Fail 'appsettings.Production.json NOT found.'
    }
} else {
    Write-Fail "Install directory not found: $InstallPath"
}

# ── 12. Local HTTPS connectivity probe ────────────────────────────────────────

Write-Header 'Section 12 . Local HTTPS connectivity probe'
Write-Check "curl.exe -k https://localhost:$HttpsPort/"

$curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curlExe) {
    $curlOut = & curl.exe -k -s -o $null -w '%{http_code}' "https://localhost:$HttpsPort/" 2>&1
    if ($curlOut -eq '200') {
        Write-Ok  "HTTP 200 — service is responding on https://localhost:$HttpsPort/"
    } elseif ($curlOut -match '^\d{3}$') {
        Write-Warn "HTTP $curlOut — service is listening but returned a non-200 status."
        Write-Info "This may be normal (e.g. redirect to /index.html).  Try in a browser."
    } elseif ($curlOut -match 'Connection refused|ECONNREFUSED') {
        Write-Fail "Connection refused — port $HttpsPort is not listening."
    } elseif ($curlOut -match 'timed out|ETIMEDOUT') {
        Write-Fail "Connection timed out — port $HttpsPort may be blocked by the firewall."
    } else {
        Write-Warn "Unexpected curl output: $curlOut"
    }
} else {
    Write-Warn 'curl.exe not found.  Testing with Invoke-WebRequest instead...'
    try {
        # PowerShell 5.1 TLS bypass
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $resp = Invoke-WebRequest -Uri "https://localhost:$HttpsPort/" `
            -TimeoutSec 5 -ErrorAction Stop -UseBasicParsing
        Write-Ok  "HTTP $($resp.StatusCode) — service is responding."
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
            Write-Fail "Connection refused — port $HttpsPort is not listening."
        } elseif ($ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
            Write-Fail "Connection timed out — firewall may be blocking the port."
        } else {
            Write-Warn "WebException ($($ex.Status)): $($ex.Message)"
        }
    } catch {
        Write-Warn "Could not probe port: $_"
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host '  |       Diagnostics Complete                           |' -ForegroundColor Cyan
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Key items to check:' -ForegroundColor DarkGray
Write-Host '    Section 2  - Is the service RUNNING?'
Write-Host '    Section 3  - Is port listening?  (FAIL here = service crashed)'
Write-Host '    Section 8/9 - Event log will show the crash reason'
Write-Host '    Section 12 - Local curl probe confirms end-to-end TLS'
Write-Host ''
Write-Host "  Full diagnostic log: $LogTranscript" -ForegroundColor DarkGray
Write-Host ''

Stop-Transcript | Out-Null

# ── Bundle on issues ───────────────────────────────────────────────────────────

if ($script:issueDetected) {
    $zipPath = $LogTranscript -replace '\.log$', '.zip'
    Compress-Archive -Path $LogTranscript -DestinationPath $zipPath -Force

    Write-Host ''
    Write-Host '  +======================================================+' -ForegroundColor Yellow
    Write-Host '  |  Issues detected - diagnostic bundle ready           |' -ForegroundColor Yellow
    Write-Host '  +======================================================+' -ForegroundColor Yellow
    Write-Host "  $zipPath" -ForegroundColor Yellow
    Write-Host ''

    # Open Explorer with the zip file pre-selected so it is easy to share
    & explorer.exe /select,"$zipPath"
}
