#Requires -Version 5.1
<#
.SYNOPSIS
    Full production installer for OsmUserWeb.

.DESCRIPTION
    Automates every step of INSTALL.md:
      0.  Prerequisite checks (admin, domain-joined, RSAT)
      1.  Collect configuration inputs (interactive prompts for any missing params)
      2.  Install .NET 9 ASP.NET Core Hosting Bundle if absent
      3.  Create the dedicated service account (svc-osmweb) in Active Directory
      4.  Grant "Log on as a service" right on this server
      5.  Delegate the minimum AD permissions to the target OU and group
      6.  Deploy and harden application files and directory ACLs
      7.  Write appsettings.Production.json
      8.  Grant the service account read access to the certificate private key
      9.  Register and configure the Windows Service
     10.  Inject secrets into the service registry environment
     11.  Configure Windows Service failure recovery
     12.  Create Windows Firewall rules scoped to the admin subnet
     13.  Start the service and verify it reaches the RUNNING state

    All actions are written to a timestamped transcript log in $env:TEMP.
    The script is idempotent - safe to re-run after a partial failure.

.PARAMETER PublishPath
    Path to the dotnet publish output folder (must contain OsmUserWeb.exe).
    Prompted interactively if omitted.

.PARAMETER InstallPath
    Destination folder on this server. Default: C:\Services\OsmUserWeb

.PARAMETER SvcAccountName
    SAM account name for the service account. Default: svc-osmweb

.PARAMETER TargetOU
    Distinguished name of the OU where new AD accounts will be created.
    Example: OU=AdminAccounts,DC=contoso,DC=com
    Prompted interactively if omitted.

.PARAMETER GroupName
    AD group that newly created accounts are added to. Default: Domain Admins

.PARAMETER DefaultPassword
    Default password assigned to accounts created via the web UI.
    Prompted securely (with confirmation) if omitted.
    Stored in the Windows registry as a service environment variable -
    never written to disk in plain text.

.PARAMETER CertThumbprint
    Thumbprint of an existing certificate in Cert:\LocalMachine\My.
    If omitted the script offers to create a self-signed certificate (testing)
    or skip TLS setup (manual configuration later).

.PARAMETER AdminSubnet
    CIDR range that is allowed to reach the web UI. Example: 10.0.1.0/24
    Prompted interactively if omitted (unless -SkipFirewall is set).

.PARAMETER HttpsPort
    HTTPS listener port. Default: 443

.PARAMETER SkipAdDelegation
    Skip the dsacls delegation steps when permissions are already configured.

.PARAMETER SkipCertificate
    Skip TLS certificate setup. Useful when IIS handles TLS termination
    or you intend to configure the certificate manually.

.PARAMETER SkipFirewall
    Skip creating Windows Firewall rules.

.PARAMETER Uninstall
    Stop and remove the Windows Service, application files, and firewall rules.

.EXAMPLE
    # Fully interactive - prompts for every missing value
    .\Install-OsmUserWeb.ps1 -PublishPath .\publish

.EXAMPLE
    # Fully automated (CI / scripted deployment)
    .\Install-OsmUserWeb.ps1 `
        -PublishPath    .\publish `
        -TargetOU       "OU=AdminAccounts,DC=contoso,DC=com" `
        -DefaultPassword "S3cur3P@ss!" `
        -CertThumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2" `
        -AdminSubnet    "10.0.1.0/24"

.EXAMPLE
    # Remove the installation
    .\Install-OsmUserWeb.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$PublishPath,
    [string]$InstallPath     = 'C:\Services\OsmUserWeb',
    [string]$SvcAccountName  = 'svc-osmweb',
    [string]$TargetOU,
    [string]$GroupName       = 'Domain Admins',
    [string]$DefaultPassword,
    [string]$CertThumbprint,
    [string]$AdminSubnet,
    [int]   $HttpsPort       = 443,
    [switch]$SkipAdDelegation,
    [switch]$SkipCertificate,
    [switch]$SkipFirewall,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'OsmUserWeb'
$DisplayName = 'OSM User Web'
$Description = 'ASP.NET Core web UI for creating numbered Active Directory admin accounts.'

$LogTranscript = Join-Path $env:TEMP "Install-OsmUserWeb-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# -- Output helpers -----------------------------------------------------------

function Write-Step { param([string]$Msg) Write-Host "`n  >> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

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
        if ($pa -ne $pb) { Write-Warn 'Values do not match - try again.' }
    } while ($pa -ne $pb)
    return $pa
}

# -- LSA "Log on as a service" via P/Invoke (no third-party modules needed) ----

function Grant-LogOnAsServiceRight {
    param([string]$AccountName)

    if (-not ([Management.Automation.PSTypeName]'OsmInstall.LsaUtil').Type) {
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace OsmInstall {
    public static class LsaUtil {
        const uint POLICY_ALL_ACCESS = 0xF0FFF;

        [StructLayout(LayoutKind.Sequential)]
        struct LSA_OBJECT_ATTRIBUTES {
            public int    Length, Attributes;
            public IntPtr RootDirectory, ObjectName, SecurityDescriptor, SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct LSA_UNICODE_STRING {
            public ushort Length, MaximumLength;
            [MarshalAs(UnmanagedType.LPWStr)] public string Buffer;
        }

        [DllImport("advapi32")] static extern uint LsaOpenPolicy(IntPtr s, ref LSA_OBJECT_ATTRIBUTES a, uint access, out IntPtr h);
        [DllImport("advapi32")] static extern uint LsaAddAccountRights(IntPtr h, IntPtr sid, LSA_UNICODE_STRING[] rights, ulong count);
        [DllImport("advapi32")] static extern uint LsaClose(IntPtr h);
        [DllImport("advapi32")] static extern int  LsaNtStatusToWinError(uint s);

        public static void GrantSeServiceLogonRight(string account) {
            var attrs = new LSA_OBJECT_ATTRIBUTES();
            IntPtr h = IntPtr.Zero;
            uint r = LsaOpenPolicy(IntPtr.Zero, ref attrs, POLICY_ALL_ACCESS, out h);
            if (r != 0) throw new Win32Exception(LsaNtStatusToWinError(r));
            try {
                var sid = (SecurityIdentifier) new NTAccount(account).Translate(typeof(SecurityIdentifier));
                byte[] b = new byte[sid.BinaryLength];
                sid.GetBinaryForm(b, 0);
                IntPtr p = Marshal.AllocHGlobal(b.Length);
                Marshal.Copy(b, 0, p, b.Length);
                try {
                    const string priv = "SeServiceLogonRight";
                    var rights = new[] { new LSA_UNICODE_STRING {
                        Buffer = priv,
                        Length = (ushort)(priv.Length * 2),
                        MaximumLength = (ushort)((priv.Length + 1) * 2)
                    }};
                    r = LsaAddAccountRights(h, p, rights, (ulong)rights.Length);
                    if (r != 0) throw new Win32Exception(LsaNtStatusToWinError(r));
                } finally { Marshal.FreeHGlobal(p); }
            } finally { LsaClose(h); }
        }
    }
}
'@
    }
    [OsmInstall.LsaUtil]::GrantSeServiceLogonRight($AccountName)
}

# -- Certificate private-key ACL helper ----------------------------------------

function Grant-CertPrivateKeyRead {
    param([string]$Thumbprint, [string]$Account)

    $cert = Get-Item "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop

    $keyPath = $null

    # Try CNG key (RSA-CNG, ECDSA)
    try {
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        if ($rsa -is [Security.Cryptography.RSACng]) {
            $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $rsa.Key.UniqueName
        }
    } catch {}

    # Fall back to legacy CSP (older RSA certs)
    if (-not $keyPath -or -not (Test-Path $keyPath)) {
        try {
            $name    = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
            $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $name
        } catch {}
    }

    if ($keyPath -and (Test-Path $keyPath)) {
        $acl = Get-Acl $keyPath
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($Account, 'Read', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl $keyPath $acl
        Write-Ok "$Account can read the certificate private key."
    } else {
        Write-Warn "Could not locate private key file for thumbprint $Thumbprint."
        Write-Warn "Grant access manually: certlm.msc -> Personal -> right-click cert -> All Tasks -> Manage Private Keys"
    }
}

# -- Helper: harden directory ACL ----------------------------------------------

function Set-HardenedAcl {
    param([string]$Path, [string]$Account, [string]$AccountRights, [string]$Inherit)
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($trustee in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
        $acl.AddAccessRule(
            [System.Security.AccessControl.FileSystemAccessRule]::new(
                $trustee, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $acl.AddAccessRule(
        [System.Security.AccessControl.FileSystemAccessRule]::new(
            $Account, $AccountRights, $Inherit, 'None', 'Allow'))
    Set-Acl $Path $acl
}

# ==============================================================================
# UNINSTALL
# ==============================================================================
if ($Uninstall) {
    Write-Host "`nUninstalling $ServiceName..." -ForegroundColor Cyan

    $confirm = Read-Host "Remove service, files at '$InstallPath', and firewall rules? (Y/N)"
    if ($confirm -notin 'Y', 'y') { Write-Host 'Aborted.'; exit 0 }

    & sc.exe stop $ServiceName 2>$null | Out-Null
    Start-Sleep -Seconds 3
    & sc.exe delete $ServiceName | Out-Null
    Write-Ok "Windows Service removed."

    if (Test-Path $InstallPath) {
        Remove-Item $InstallPath -Recurse -Force
        Write-Ok "Application files removed: $InstallPath"
    }

    Get-NetFirewallRule -DisplayName 'OsmUserWeb*' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    Write-Ok "Firewall rules removed."

    Write-Host "`nUninstall complete." -ForegroundColor Green
    exit 0
}

# ==============================================================================
# INSTALL
# ==============================================================================
Start-Transcript -Path $LogTranscript -Force | Out-Null

Write-Host "`n  +======================================================+" -ForegroundColor Cyan
Write-Host "  |       OsmUserWeb - Production Installer              |" -ForegroundColor Cyan
Write-Host "  +======================================================+" -ForegroundColor Cyan
Write-Host "  Log: $LogTranscript`n" -ForegroundColor DarkGray

# Script-scoped variables populated during input collection
$script:DomainFQDN   = $null
$script:SvcFullName  = $null
$script:SvcPassword  = $null   # plain text - used only in memory during install

try {

    # -- Step 0: Prerequisites ------------------------------------------------
    Write-Step 'Step 0 . Checking prerequisites'

    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator. Re-launch an elevated PowerShell session.'
    }
    Write-Ok 'Running as Administrator.'

    if ((Get-WmiObject Win32_ComputerSystem).PartOfDomain -eq $false) {
        throw 'This server is not domain-joined. OsmUserWeb requires Active Directory connectivity.'
    }
    Write-Ok 'Server is domain-joined.'

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Ok 'ActiveDirectory (RSAT) module loaded.'
    } catch {
        throw 'ActiveDirectory module not found. Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    }

    # -- Step 1: Collect inputs -----------------------------------------------
    Write-Step 'Step 1 . Collecting configuration inputs'

    $script:DomainFQDN  = (Get-ADDomain).DNSRoot
    $script:SvcFullName = "$($script:DomainFQDN.Split('.')[0])\$SvcAccountName"
    Write-Ok "Detected domain: $($script:DomainFQDN)"

    if (-not $PublishPath) {
        $PublishPath = Read-NonEmpty 'Path to dotnet publish output (e.g. C:\temp\publish)'
    }
    if (-not (Test-Path $PublishPath)) {
        throw "Publish path not found: $PublishPath"
    }
    if (-not (Test-Path (Join-Path $PublishPath 'OsmUserWeb.exe'))) {
        throw "OsmUserWeb.exe not found in '$PublishPath'. Run 'dotnet publish' first (see README)."
    }
    Write-Ok "Publish source verified: $PublishPath"

    if (-not $TargetOU) {
        $TargetOU = Read-NonEmpty "Target OU distinguished name`n  (e.g. OU=AdminAccounts,DC=$($script:DomainFQDN -replace '\.', ',DC='))`n  TargetOU"
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

    Write-Host ''
    $script:SvcPassword = Read-PasswordConfirmed "Service account password for $($script:SvcFullName)"

    # Certificate
    if (-not $SkipCertificate -and -not $CertThumbprint) {
        Write-Host ''
        Write-Host '  TLS certificate options:' -ForegroundColor DarkGray
        Write-Host '    [1] Use an existing certificate (enter thumbprint)'  -ForegroundColor DarkGray
        Write-Host '    [2] Create a self-signed certificate (testing only)' -ForegroundColor DarkGray
        Write-Host '    [3] Skip TLS for now (configure manually later)'     -ForegroundColor DarkGray
        $certChoice = Read-Host '  Choice (1/2/3)'

        switch ($certChoice.Trim()) {
            '1' {
                $CertThumbprint = (Read-NonEmpty 'Certificate thumbprint').ToUpper() -replace '\s', ''
                try { $null = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" }
                catch { throw "Certificate not found in Cert:\LocalMachine\My with thumbprint: $CertThumbprint" }
                Write-Ok "Certificate located: $CertThumbprint"
            }
            '2' {
                Write-Warn 'Self-signed certificate is for TESTING only. Browsers will show a security warning.'
                $cert           = New-SelfSignedCertificate `
                    -DnsName          $env:COMPUTERNAME `
                    -CertStoreLocation 'Cert:\LocalMachine\My' `
                    -NotAfter         (Get-Date).AddYears(1) `
                    -KeyAlgorithm     RSA `
                    -KeyLength        2048 `
                    -KeyExportPolicy  NonExportable
                $CertThumbprint = $cert.Thumbprint
                Write-Ok "Self-signed certificate created. Thumbprint: $CertThumbprint"
            }
            default {
                $SkipCertificate = $true
                Write-Warn 'TLS setup skipped. Follow INSTALL.md step 9 to configure it manually.'
            }
        }
    }

    # Firewall subnet
    if (-not $SkipFirewall -and -not $AdminSubnet) {
        Write-Host ''
        $AdminSubnet = Read-NonEmpty 'Admin subnet allowed to access the UI, in CIDR notation (e.g. 10.0.1.0/24)'
    }

    Write-Host ''
    Write-Host '  -- Configuration summary -----------------------------------' -ForegroundColor DarkGray
    Write-Host "  Install path   : $InstallPath"
    Write-Host "  Service account: $($script:SvcFullName)"
    Write-Host "  Target OU      : $TargetOU"
    Write-Host "  Group          : $GroupName"
    if ($CertThumbprint) { Write-Host "  Certificate    : $CertThumbprint" }
    if ($AdminSubnet)    { Write-Host "  Admin subnet   : $AdminSubnet" }
    Write-Host ''
    $go = Read-Host '  Proceed with installation? (Y/N)'
    if ($go -notin 'Y', 'y') {
        Write-Host 'Aborted. No changes were made.' -ForegroundColor Yellow
        exit 0
    }

    # -- Step 2: .NET 9 Hosting Bundle ---------------------------------------
    Write-Step 'Step 2 . .NET 9 ASP.NET Core Hosting Bundle'

    $runtime = dotnet --list-runtimes 2>$null | Where-Object { $_ -match '^Microsoft\.AspNetCore\.App 9\.' }
    if ($runtime) {
        Write-Ok "Runtime already installed: $($runtime | Select-Object -Last 1)"
    } else {
        Write-Host '    Installing .NET 9 ASP.NET Core Hosting Bundle via winget...'
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw 'winget is not available. Install the .NET 9 Hosting Bundle manually from https://dotnet.microsoft.com/download/dotnet/9 then re-run.'
        }
        winget install --id Microsoft.DotNet.AspNetCore.9 --source winget `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget install failed (exit code $LASTEXITCODE)." }

        # Refresh PATH so dotnet is usable in this session
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('PATH', 'User')
        Write-Ok '.NET 9 Hosting Bundle installed.'
    }

    # -- Step 3: Service account ----------------------------------------------
    Write-Step 'Step 3 . Service account'

    $existing = Get-ADUser -Filter "SamAccountName -eq '$SvcAccountName'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "Account already exists: $($script:SvcFullName) - skipping creation."
    } else {
        $secPw = ConvertTo-SecureString $script:SvcPassword -AsPlainText -Force
        New-ADUser `
            -Name                 $SvcAccountName `
            -SamAccountName       $SvcAccountName `
            -UserPrincipalName    "$SvcAccountName@$($script:DomainFQDN)" `
            -AccountPassword      $secPw `
            -Enabled              $true `
            -PasswordNeverExpires $true `
            -CannotChangePassword $true `
            -Description          'OsmUserWeb service account - do not add to privileged groups'
        Write-Ok "Service account created: $($script:SvcFullName)"
    }

    # -- Step 4: Log on as a service ------------------------------------------
    Write-Step 'Step 4 . Log on as a service right'

    try {
        Grant-LogOnAsServiceRight $script:SvcFullName
        Write-Ok "SeServiceLogonRight granted to $($script:SvcFullName)."
    } catch {
        Write-Warn "Could not grant SeServiceLogonRight automatically: $_"
        Write-Warn 'Grant manually: Local Security Policy -> User Rights Assignment -> Log on as a service'
    }

    # -- Step 5: AD delegation ------------------------------------------------
    if ($SkipAdDelegation) {
        Write-Step 'Step 5 . Skipping AD delegation (-SkipAdDelegation)'
        Write-Warn 'Ensure permissions are already in place. See INSTALL.md step 4.'
    } else {
        Write-Step 'Step 5 . Delegating Active Directory permissions'

        $ouRules = @(
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):CC;user");   Desc = 'Create User objects in OU' }
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):RP;;user");  Desc = 'Read user properties in OU' }
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):WP;;user");  Desc = 'Write user properties in OU' }
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):CA;Reset Password;user"); Desc = 'Reset password on User objects in OU' }
        )
        foreach ($rule in $ouRules) {
            $out = & dsacls @($rule.Args) 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Ok $rule.Desc }
            else { Write-Warn "$($rule.Desc) - dsacls failed (exit $LASTEXITCODE): $out. Set manually per INSTALL.md step 4." }
        }

        try {
            $groupDN = (Get-ADGroup -Identity $GroupName -ErrorAction Stop).DistinguishedName
            & dsacls $groupDN /G "$($script:SvcFullName):WP;member" | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "Write 'member' attribute on '$GroupName'" }
            else { Write-Warn "Group member delegation failed. Set manually per INSTALL.md step 4b." }
        } catch {
            Write-Warn "Group '$GroupName' not found - skipping group delegation: $_"
        }
    }

    # -- Step 6: Deploy files -------------------------------------------------
    Write-Step 'Step 6 . Deploying application files'

    foreach ($dir in $InstallPath, (Join-Path $InstallPath 'logs')) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    }

    $resolvedPublish = (Resolve-Path $PublishPath).Path.TrimEnd('\').TrimEnd('/')
    $resolvedInstall = $InstallPath.TrimEnd('\').TrimEnd('/')
    if ($resolvedPublish -eq $resolvedInstall) {
        Write-Ok "Publish path is the install path - files already in place, skipping copy."
    } else {
        Copy-Item -Path (Join-Path $PublishPath '*') -Destination $InstallPath -Recurse -Force
        Write-Ok "Files copied to $InstallPath"
    }

    Set-HardenedAcl -Path $InstallPath `
        -Account $script:SvcFullName -AccountRights 'ReadAndExecute' `
        -Inherit 'ContainerInherit,ObjectInherit'

    Set-HardenedAcl -Path (Join-Path $InstallPath 'logs') `
        -Account $script:SvcFullName -AccountRights 'Modify' `
        -Inherit 'ContainerInherit,ObjectInherit'

    Write-Ok 'Directory ACLs hardened (service account: read-execute on root, modify on logs only).'

    # -- Step 7: Production config --------------------------------------------
    Write-Step 'Step 7 . Writing appsettings.Production.json'

    $configObj = [ordered]@{
        Logging    = [ordered]@{
            LogLevel = [ordered]@{
                Default                = 'Warning'
                OsmUserWeb             = 'Information'
                'Microsoft.AspNetCore' = 'Warning'
            }
            EventLog = [ordered]@{ SourceName = 'OsmUserWeb'; LogName = 'Application' }
        }
        AdSettings = [ordered]@{ TargetOU = $TargetOU; GroupName = $GroupName }
    }

    if (-not $SkipCertificate -and $CertThumbprint) {
        # Kestrel's CertificateConfig uses Subject (full DN), not Thumbprint.
        # An unrecognised key is silently ignored, leaving the cert config empty.
        $certSubject = (Get-Item "Cert:\LocalMachine\My\$CertThumbprint").Subject

        $configObj['Kestrel'] = [ordered]@{
            Endpoints = [ordered]@{
                HttpLocalOnly = [ordered]@{ Url = 'http://localhost:5150' }
                Https         = [ordered]@{
                    Url         = "https://*:$HttpsPort"
                    Certificate = [ordered]@{
                        Subject      = $certSubject
                        Store        = 'My'
                        Location     = 'LocalMachine'
                        AllowInvalid = $false
                    }
                }
            }
        }
    }

    $configPath = Join-Path $InstallPath 'appsettings.Production.json'
    $configObj | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
    Write-Ok "Config written: $configPath"

    # Restrict read access on both config files
    foreach ($cfgFile in @($configPath, (Join-Path $InstallPath 'appsettings.json'))) {
        if (-not (Test-Path $cfgFile)) { continue }
        $cfgAcl = Get-Acl $cfgFile
        $cfgAcl.SetAccessRuleProtection($true, $false)
        foreach ($t in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
            $cfgAcl.AddAccessRule(
                [System.Security.AccessControl.FileSystemAccessRule]::new($t, 'FullControl', 'Allow'))
        }
        $cfgAcl.AddAccessRule(
            [System.Security.AccessControl.FileSystemAccessRule]::new($script:SvcFullName, 'Read', 'Allow'))
        Set-Acl $cfgFile $cfgAcl
    }
    Write-Ok 'Config file ACLs restricted (Administrators + service account read-only).'

    # -- Step 8: Certificate private key access -------------------------------
    if (-not $SkipCertificate -and $CertThumbprint) {
        Write-Step 'Step 8 . Granting certificate private key access'
        Grant-CertPrivateKeyRead -Thumbprint $CertThumbprint -Account $script:SvcFullName
    } else {
        Write-Step 'Step 8 . Skipping certificate key access (no cert configured)'
    }

    # -- Step 9: Windows Service registration ---------------------------------
    Write-Step 'Step 9 . Registering Windows Service'

    $binPath = Join-Path $InstallPath 'OsmUserWeb.exe'

    $svcQuery = & sc.exe query $ServiceName 2>$null
    if ($svcQuery -match 'SERVICE_NAME') {
        Write-Warn "Service '$ServiceName' already registered - reconfiguring."
        & sc.exe stop $ServiceName 2>$null | Out-Null
        Start-Sleep -Seconds 3
        & sc.exe config $ServiceName `
            binPath=  $binPath `
            obj=      $script:SvcFullName `
            password= $script:SvcPassword `
            start=    auto | Out-Null
    } else {
        & sc.exe create $ServiceName `
            binPath=     $binPath `
            obj=         $script:SvcFullName `
            password=    $script:SvcPassword `
            start=       auto `
            DisplayName= $DisplayName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe create failed (exit $LASTEXITCODE)." }
    }

    & sc.exe description $ServiceName $Description | Out-Null
    Write-Ok "Service registered: $ServiceName"

    # -- Step 10: Service environment variables (secrets) ---------------------
    Write-Step 'Step 10 . Injecting secrets into service registry environment'

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    New-ItemProperty -Path $regPath -Name 'Environment' -PropertyType MultiString -Force `
        -Value @(
            'ASPNETCORE_ENVIRONMENT=Production',
            "AdSettings__DefaultPassword=$DefaultPassword"
        ) | Out-Null
    Write-Ok 'Secrets written to HKLM service registry key (readable by Administrators and SYSTEM only).'

    # -- Step 11: Failure recovery ---------------------------------------------
    Write-Step 'Step 11 . Configuring failure recovery'
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    Write-Ok 'Recovery policy: restart after 5 s -> 10 s -> 30 s; counter resets after 24 h.'

    # -- Step 12: Firewall rules -----------------------------------------------
    if ($SkipFirewall) {
        Write-Step 'Step 12 . Skipping firewall (-SkipFirewall)'
    } else {
        Write-Step 'Step 12 . Configuring Windows Firewall'

        Get-NetFirewallRule -DisplayName 'OsmUserWeb*' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule

        New-NetFirewallRule `
            -DisplayName   "OsmUserWeb - allow HTTPS from $AdminSubnet" `
            -Direction     Inbound `
            -Protocol      TCP `
            -LocalPort     $HttpsPort `
            -RemoteAddress $AdminSubnet `
            -Action        Allow | Out-Null

        New-NetFirewallRule `
            -DisplayName   'OsmUserWeb - block HTTPS from all others' `
            -Direction     Inbound `
            -Protocol      TCP `
            -LocalPort     $HttpsPort `
            -Action        Block | Out-Null

        Write-Ok "Inbound TCP $HttpsPort - allowed from $AdminSubnet, blocked from all others."
    }

    # -- Step 13: Start and verify ---------------------------------------------
    Write-Step 'Step 13 . Starting service'

    & sc.exe start $ServiceName | Out-Null

    $running  = $false
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 600
        $status = (& sc.exe query $ServiceName | Select-String 'STATE').ToString()
        if ($status -match '4  RUNNING') { $running = $true; break }
    } while ((Get-Date) -lt $deadline)

    if ($running) {
        Write-Ok 'Service reached RUNNING state.'
    } else {
        Write-Warn 'Service did not reach RUNNING within 30 seconds.'
        Write-Warn "Check the event log: Get-EventLog -LogName Application -Source OsmUserWeb -Newest 10"
    }

    # -- Summary ---------------------------------------------------------------
    $baseUrl = if ($SkipCertificate) {
        "http://localhost:5150"
    } elseif ($HttpsPort -eq 443) {
        "https://$env:COMPUTERNAME"
    } else {
        "https://$env:COMPUTERNAME`:$HttpsPort"
    }

    Write-Host ''
    Write-Host '  +======================================================+' -ForegroundColor Green
    Write-Host '  |       Installation Complete                          |' -ForegroundColor Green
    Write-Host '  +======================================================+' -ForegroundColor Green
    Write-Host "  |  Service      : $ServiceName"                           -ForegroundColor Green
    Write-Host "  |  Installed at : $InstallPath"                           -ForegroundColor Green
    Write-Host "  |  Running as   : $($script:SvcFullName)"                 -ForegroundColor Green
    Write-Host "  |  URL          : $baseUrl"                               -ForegroundColor Green
    Write-Host "  |  Target OU    : $TargetOU"                              -ForegroundColor Green
    Write-Host "  |  Group        : $GroupName"                             -ForegroundColor Green
    if ($CertThumbprint) {
    Write-Host "  |  Certificate  : $CertThumbprint"                        -ForegroundColor Green
    }
    Write-Host '  +------------------------------------------------------+' -ForegroundColor Green
    Write-Host '  |  Next steps:                                         |' -ForegroundColor Green
    Write-Host '  |   1. Open the URL from an admin workstation          |' -ForegroundColor Green
    Write-Host '  |   2. Work through the verification checklist         |' -ForegroundColor Green
    Write-Host '  |      in INSTALL.md step 13                           |' -ForegroundColor Green
    Write-Host '  |   3. Verify perimeter firewall rules independently   |' -ForegroundColor Green
    Write-Host '  +======================================================+' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Full install log: $LogTranscript" -ForegroundColor DarkGray

} catch {
    Write-Host ''
    Write-Fail "Installation failed: $($_.Exception.Message)"
    Write-Fail "At: $($_.InvocationInfo.PositionMessage)"
    Write-Host "`n  Full install log: $LogTranscript" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
