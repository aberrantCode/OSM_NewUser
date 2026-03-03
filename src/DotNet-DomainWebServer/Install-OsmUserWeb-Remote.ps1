#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates a remote installation of OsmUserWeb from an admin workstation.

.DESCRIPTION
    Split-hop approach — avoids the PS Remoting double-hop problem:

      LOCAL (this workstation, where RSAT and a DC connection are available):
        - Collect all configuration inputs
        - Create the svc-osmweb service account in Active Directory
        - Delegate the minimum AD permissions on the target OU and group

      REMOTE (target server, via Invoke-Command over WinRM):
        - Install .NET 9 Hosting Bundle if absent
        - Grant "Log on as a service" right
        - Deploy and harden application files
        - Write appsettings.Production.json
        - Register certificate with HTTP.sys (netsh urlacl + sslcert)
        - Register and configure the Windows Service
        - Inject secrets into service registry environment
        - Configure firewall rules
        - Start and verify the service

    Prerequisites on the admin workstation:
      - PowerShell 5.1+
      - RSAT / ActiveDirectory module
      - Reachable domain controller
      - WinRM connectivity to the target server (Test-NetConnection <server> -Port 5985)

    Prerequisites on the target server:
      - WinRM enabled (Enable-PSRemoting)
      - The supplied -Credential must be a local Administrator

.PARAMETER TargetServer
    Hostname or IP of the target server.

.PARAMETER Credential
    Credentials for the PS Remoting session. Must have local Administrator rights
    on the target server. Defaults to the current user's credentials.

.PARAMETER PublishPath
    Local path to the dotnet publish output folder (must contain OsmUserWeb.exe).
    Prompted interactively if omitted.

.PARAMETER InstallPath
    Installation directory on the target server. Default: C:\Services\OsmUserWeb

.PARAMETER SvcAccountName
    SAM account name for the service account. Default: svc-osmweb

.PARAMETER SvcAccountPassword
    Password for the service account (used for AD account creation and sc.exe create).
    Prompted interactively if omitted.

.PARAMETER TargetOU
    Distinguished name of the OU where new AD accounts will be created.
    Example: OU=AdminAccounts,DC=contoso,DC=com
    Prompted interactively if omitted.

.PARAMETER GroupName
    AD group that newly created accounts are added to. Default: Domain Admins

.PARAMETER DefaultPassword
    Default password assigned to accounts created via the web UI.
    Prompted interactively if omitted.

.PARAMETER CertPfxPath
    Local path to a PFX file containing the TLS certificate and private key.
    The file is copied to the target server and imported there.
    Omit to use -CertSelfSigned or -SkipCertificate.

.PARAMETER CertPfxPassword
    Password for the PFX file supplied via -CertPfxPath.
    Prompted interactively if -CertPfxPath is given but this is omitted.

.PARAMETER CertSelfSigned
    Create (or reuse) a self-signed certificate on the target server.
    Useful for lab or internal deployments.

.PARAMETER AdminSubnet
    CIDR range allowed to reach the web UI. Example: 10.0.1.0/24
    Prompted interactively if omitted (unless -SkipFirewall is set).

.PARAMETER HttpsPort
    HTTPS listener port. Default: 8443

.PARAMETER SkipAdDelegation
    Skip the dsacls delegation steps when permissions are already configured.

.PARAMETER SkipCertificate
    Skip TLS certificate setup entirely.

.PARAMETER SkipFirewall
    Skip creating Windows Firewall rules.

.EXAMPLE
    # Minimal — prompts for all required inputs
    .\Install-OsmUserWeb-Remote.ps1 -TargetServer AC-WINADMIN

.EXAMPLE
    # Fully scripted
    .\Install-OsmUserWeb-Remote.ps1 `
        -TargetServer       AC-WINADMIN `
        -Credential         (Get-Credential "opbta\Administrator") `
        -PublishPath        .\publish `
        -TargetOU           "OU=AdminAccounts,DC=opbta,DC=local" `
        -DefaultPassword    "S3cur3P@ss!" `
        -SvcAccountPassword "SvcP@ss!" `
        -CertSelfSigned `
        -AdminSubnet        "10.0.1.0/24"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetServer,

    [PSCredential]$Credential,

    [string]$PublishPath,
    [string]$InstallPath        = 'C:\Services\OsmUserWeb',
    [string]$SvcAccountName     = 'svc-osmweb',
    [string]$SvcAccountPassword,
    [string]$TargetOU,
    [string]$GroupName          = 'Domain Admins',
    [string]$DefaultPassword,
    [string]$CertPfxPath,
    [string]$CertPfxPassword,
    [switch]$CertSelfSigned,
    [string]$AdminSubnet,
    [int]   $HttpsPort          = 8443,
    [switch]$SkipAdDelegation,
    [switch]$SkipCertificate,
    [switch]$SkipFirewall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Msg) Write-Host "`n  >> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }

function Read-NonEmpty {
    param([string]$Prompt)
    do { $v = (Read-Host $Prompt).Trim() } while ([string]::IsNullOrWhiteSpace($v))
    return $v
}

function Read-PasswordConfirmed {
    param([string]$Label)
    do {
        $a = Read-Host "$Label" -AsSecureString
        $b = Read-Host "Confirm $Label" -AsSecureString
        $pa = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $pb = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if ($pa -ne $pb) { Write-Warn 'Values do not match — try again.' }
    } while ($pa -ne $pb)
    return $pa
}

# ==============================================================================

Write-Host "`n  +======================================================+" -ForegroundColor Cyan
Write-Host "  |       OsmUserWeb - Remote Installer                  |" -ForegroundColor Cyan
Write-Host "  +======================================================+`n" -ForegroundColor Cyan

# -- Step 0: Local prerequisites -------------------------------------------
Write-Step 'Step 0 . Checking local prerequisites'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as Administrator on the admin workstation.'
}
Write-Ok 'Running as Administrator.'

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Ok 'ActiveDirectory (RSAT) module loaded.'
} catch {
    Write-Warn 'ActiveDirectory module not found (RSAT not installed).'
    $install = Read-Host '    Install RSAT now? This requires internet access. (Y/N)'
    if ($install -notin 'Y', 'y') {
        throw 'RSAT is required. Run manually: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    }
    Write-Host '    Installing RSAT ActiveDirectory tools (this may take a minute)...' -ForegroundColor Cyan
    $cap = Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' -ErrorAction Stop
    if ($cap.RestartNeeded) {
        throw 'RSAT installed but a restart is required. Reboot and re-run this script.'
    }
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Ok 'ActiveDirectory (RSAT) module installed and loaded.'
}

$localDomain     = Get-ADDomain
$domainFQDN      = $localDomain.DNSRoot
$domainShort     = $localDomain.NetBIOSName
$svcFullName     = "$domainShort\$SvcAccountName"
Write-Ok "Domain: $domainFQDN (NetBIOS: $domainShort)"

# Verify the companion installer script is present alongside this script
$installerScript = Join-Path $PSScriptRoot 'Install-OsmUserWeb.ps1'
if (-not (Test-Path $installerScript)) {
    throw "Install-OsmUserWeb.ps1 not found in $PSScriptRoot. Both scripts must be in the same directory."
}
Write-Ok "Installer script found: $installerScript"

# -- Step 1: Collect inputs ------------------------------------------------
Write-Step 'Step 1 . Collecting configuration inputs'

if (-not $PublishPath) {
    $defaultPublish = Join-Path $PSScriptRoot 'app'
    $v = (Read-Host "Local path to dotnet publish output [$defaultPublish]").Trim()
    $PublishPath = if ([string]::IsNullOrWhiteSpace($v)) { $defaultPublish } else { $v }
}
$PublishPath = (Resolve-Path $PublishPath).Path
if (-not (Test-Path (Join-Path $PublishPath 'OsmUserWeb.exe'))) {
    throw "OsmUserWeb.exe not found in: $PublishPath"
}
Write-Ok "Publish source: $PublishPath"

if (-not $TargetOU) {
    $TargetOU = Read-NonEmpty "Target OU distinguished name`n  (e.g. OU=AdminAccounts,DC=$($domainFQDN -replace '\.', ',DC='))`n  TargetOU"
}
try {
    $null = Get-ADOrganizationalUnit -Identity $TargetOU
    Write-Ok "Target OU verified: $TargetOU"
} catch {
    throw "Target OU not found in AD: $TargetOU"
}

if (-not $DefaultPassword) {
    Write-Host ''
    $DefaultPassword = Read-PasswordConfirmed 'Default password for new AD accounts'
}

if (-not $SvcAccountPassword) {
    Write-Host ''
    $SvcAccountPassword = Read-PasswordConfirmed "Service account password for $svcFullName"
}

# Certificate
if (-not $SkipCertificate -and -not $CertPfxPath -and -not $CertSelfSigned) {
    Write-Host ''
    Write-Host '  TLS certificate options:' -ForegroundColor DarkGray
    Write-Host '    [1] Use an existing PFX file (certificate + private key)' -ForegroundColor DarkGray
    Write-Host '    [2] Create a self-signed certificate on the target server (testing only)' -ForegroundColor DarkGray
    Write-Host '    [3] Skip TLS for now (configure manually later)'          -ForegroundColor DarkGray
    $certChoice = Read-Host '  Choice (1/2/3)'

    switch ($certChoice.Trim()) {
        '1' {
            $CertPfxPath = Read-NonEmpty 'Local path to PFX file'
            if (-not (Test-Path $CertPfxPath)) { throw "PFX file not found: $CertPfxPath" }
        }
        '2' { $CertSelfSigned = $true }
        default {
            $SkipCertificate = $true
            Write-Warn 'TLS setup skipped. Follow INSTALL.md step 9 to configure it manually.'
        }
    }
}

if ($CertPfxPath -and -not $CertPfxPassword) {
    Write-Host ''
    $CertPfxPassword = Read-PasswordConfirmed 'PFX password'
}

if (-not $SkipFirewall -and -not $AdminSubnet) {
    Write-Host ''
    $AdminSubnet = Read-NonEmpty 'Admin subnet allowed to access the UI, in CIDR notation (e.g. 10.0.1.0/24)'
}

# Confirmation summary
Write-Host ''
Write-Host '  -- Configuration summary -----------------------------------' -ForegroundColor DarkGray
Write-Host "  Target server  : $TargetServer"
Write-Host "  Install path   : $InstallPath"
Write-Host "  Service account: $svcFullName"
Write-Host "  Target OU      : $TargetOU"
Write-Host "  Group          : $GroupName"
if ($CertSelfSigned)     { Write-Host '  Certificate    : self-signed (created on target server)' }
elseif ($CertPfxPath)    { Write-Host "  Certificate PFX: $CertPfxPath (will be copied to server)" }
elseif ($SkipCertificate){ Write-Host '  Certificate    : skipped' }
if ($AdminSubnet)        { Write-Host "  Admin subnet   : $AdminSubnet" }
Write-Host ''

$go = Read-Host '  Proceed? (Y/N)'
if ($go -notin 'Y', 'y') {
    Write-Host 'Aborted. No changes were made.' -ForegroundColor Yellow
    exit 0
}

# -- Step 2: Create service account (local AD) -----------------------------
Write-Step 'Step 2 . Service account (local AD)'

$existing = Get-ADUser -Filter "SamAccountName -eq '$SvcAccountName'" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Ok "Account already exists: $svcFullName — skipping creation."
} else {
    $secPw = ConvertTo-SecureString $SvcAccountPassword -AsPlainText -Force
    New-ADUser `
        -Name                 $SvcAccountName `
        -SamAccountName       $SvcAccountName `
        -UserPrincipalName    "$SvcAccountName@$domainFQDN" `
        -AccountPassword      $secPw `
        -Enabled              $true `
        -PasswordNeverExpires $true `
        -CannotChangePassword $true `
        -Description          'OsmUserWeb service account — do not add to privileged groups'
    Write-Ok "Service account created: $svcFullName"
}

# -- Step 3: AD delegation (local) ----------------------------------------
if ($SkipAdDelegation) {
    Write-Step 'Step 3 . Skipping AD delegation (-SkipAdDelegation)'
    Write-Warn 'Ensure permissions are already in place. See INSTALL.md step 4.'
} else {
    Write-Step 'Step 3 . Delegating Active Directory permissions (local)'

    $ouRules = @(
        @{ Args = @($TargetOU, '/G', "${svcFullName}:CC;user");                     Desc = 'Create User objects in OU' }
        @{ Args = @($TargetOU, '/G', "${svcFullName}:RP;;user",  '/I:S');           Desc = 'Read user properties in OU' }
        @{ Args = @($TargetOU, '/G', "${svcFullName}:WP;;user",  '/I:S');           Desc = 'Write user properties in OU' }
        @{ Args = @($TargetOU, '/G', "${svcFullName}:CA;Reset Password;user", '/I:S'); Desc = 'Reset password on User objects in OU' }
    )
    foreach ($rule in $ouRules) {
        $out = & dsacls @($rule.Args) 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Ok $rule.Desc }
        else { Write-Warn "$($rule.Desc) — dsacls failed (exit $LASTEXITCODE): $out" }
    }

    try {
        $groupDN = (Get-ADGroup -Identity $GroupName -ErrorAction Stop).DistinguishedName
        & dsacls $groupDN /G "${svcFullName}:WP;member" | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Write 'member' attribute on '$GroupName'" }
        else { Write-Warn "Group member delegation failed. Set manually per INSTALL.md step 4b." }
    } catch {
        Write-Warn "Group '$GroupName' not found — skipping group delegation: $_"
    }
}

# -- Step 4: Open PS Remoting session to target server ---------------------
Write-Step "Step 4 . Opening PS Remoting session to $TargetServer"

$sessParams = @{ ComputerName = $TargetServer; ErrorAction = 'Stop' }
if ($Credential) { $sessParams['Credential'] = $Credential }
$sess = New-PSSession @sessParams
Write-Ok "Connected to $TargetServer"

$remoteTemp = "C:\Windows\Temp\OsmInstall-$(New-Guid)"

try {
    # -- Step 5: Copy files to target server -------------------------------
    Write-Step 'Step 5 . Copying files to target server'

    # Create the temp staging directory on the remote server
    Invoke-Command -Session $sess -ScriptBlock {
        param($t)
        New-Item -ItemType Directory -Path $t -Force | Out-Null
    } -ArgumentList $remoteTemp

    # Copy publish output
    Write-Host "    Copying publish output ($PublishPath)..."
    Copy-Item -Path $PublishPath -Destination "$remoteTemp\publish" -ToSession $sess -Recurse -Force
    Write-Ok 'Publish output copied.'

    # Copy the installer script
    Copy-Item -Path $installerScript -Destination "$remoteTemp\" -ToSession $sess -Force
    Write-Ok 'Installer script copied.'

    # Copy PFX if a local path was supplied
    $remotePfxPath = $null
    if ($CertPfxPath) {
        Copy-Item -Path $CertPfxPath -Destination "$remoteTemp\osmweb.pfx" -ToSession $sess -Force
        $remotePfxPath = "$remoteTemp\osmweb.pfx"
        Write-Ok "PFX copied to remote: $remotePfxPath"
    }

    # -- Step 6: Run installer on target server ----------------------------
    Write-Step 'Step 6 . Running installer on target server'

    # Convert switches to plain booleans so $using: captures them correctly
    $certSelfSignedBool  = $CertSelfSigned.IsPresent
    $skipCertBool        = $SkipCertificate.IsPresent
    $skipFwBool          = $SkipFirewall.IsPresent
    $skipAdDelegBool     = $SkipAdDelegation.IsPresent

    Invoke-Command -Session $sess -ScriptBlock {
        $installerArgs = @{
            PublishPath        = "$using:remoteTemp\publish"
            InstallPath        = $using:InstallPath
            SvcAccountName     = $using:SvcAccountName
            SvcAccountPassword = $using:SvcAccountPassword
            TargetOU           = $using:TargetOU
            GroupName          = $using:GroupName
            DefaultPassword    = $using:DefaultPassword
            HttpsPort          = $using:HttpsPort
            SkipAdAccount      = $true   # handled locally in steps 2–3
            SkipAdDelegation   = $true   # handled locally in steps 2–3
            Force              = $true   # non-interactive remote session
        }

        if ($using:certSelfSignedBool)  { $installerArgs['CertSelfSigned']   = $true }
        if ($using:remotePfxPath)       {
            $installerArgs['CertPfxPath']     = $using:remotePfxPath
            $installerArgs['CertPfxPassword'] = $using:CertPfxPassword
        }
        if ($using:skipCertBool)        { $installerArgs['SkipCertificate']  = $true }
        if ($using:skipFwBool)          { $installerArgs['SkipFirewall']      = $true }
        if ($using:AdminSubnet)         { $installerArgs['AdminSubnet']       = $using:AdminSubnet }

        & "$using:remoteTemp\Install-OsmUserWeb.ps1" @installerArgs
    }

} finally {
    # -- Step 7: Clean up remote staging directory -------------------------
    Write-Step 'Step 7 . Cleaning up remote temp files'
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
    Write-Ok "PS Remoting session closed."
}

# -- Done ------------------------------------------------------------------
$baseUrl = if ($SkipCertificate) { "http://${TargetServer}:5150" } else { "https://${TargetServer}:$HttpsPort" }

Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host '  |       Remote Installation Complete                   |' -ForegroundColor Green
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host "  |  Server  : $TargetServer"                               -ForegroundColor Green
Write-Host "  |  URL     : $baseUrl"                                    -ForegroundColor Green
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host ''
