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

.PARAMETER SvcAccountPassword
    Password for the service account used in sc.exe create.
    Prompted interactively if omitted.
    Supply this to run non-interactively (e.g. via Invoke-Command).

.PARAMETER TargetOU
    Distinguished name of the OU where new AD accounts will be created.
    Default: OU=AdminAccounts,DC=opbta,DC=local
    Prompted interactively showing the default unless -Force is set.

.PARAMETER GroupName
    AD group that newly created accounts are added to. Default: Domain Admins

.PARAMETER DefaultPassword
    Default password assigned to accounts created via the web UI.
    Prompted securely (with confirmation) if omitted.
    Stored in the Windows registry as a service environment variable -
    never written to disk in plain text.

.PARAMETER CertPfxPath
    Path to a PFX file containing the TLS certificate and private key.
    If omitted, the installer checks <InstallPath>\certs\osmweb.pfx first (re-install scenario).
    If that does not exist either, the interactive TLS certificate menu is displayed.
    Prompted interactively showing the default unless -Force or -SkipCertificate is set.

.PARAMETER CertPfxPassword
    Password for the PFX file supplied via -CertPfxPath.
    Prompted interactively if -CertPfxPath is given but this is omitted.

.PARAMETER AdminSubnet
    CIDR range that is allowed to reach the web UI.
    Default: 192.168.0.0/24
    Prompted interactively showing the default unless -Force or -SkipFirewall is set.

.PARAMETER HttpsPort
    HTTPS listener port. Default: 8443
    Port 443 requires Administrator or HTTP.sys rights; svc-osmweb cannot bind
    to a raw socket below 1024.  Use 8443 (or any port >= 1024) and rely on
    the Windows Firewall rule to restrict access to the admin subnet.

.PARAMETER SkipAdAccount
    Skip Step 3 (creating the service account in Active Directory).
    Use when the account has already been created by the calling script, or
    when running via PS Remoting where the DC is not directly reachable (double-hop).

.PARAMETER SkipAdDelegation
    Skip the dsacls delegation steps when permissions are already configured.

.PARAMETER SkipCertificate
    Skip TLS certificate setup. Useful when IIS handles TLS termination
    or you intend to configure the certificate manually.

.PARAMETER CertSelfSigned
    Create (or reuse) a self-signed certificate without displaying the interactive
    certificate-method menu. Equivalent to choosing option [2] at the prompt.
    Use for non-interactive / remote execution.

.PARAMETER SkipFirewall
    Skip creating Windows Firewall rules.

.PARAMETER Force
    Skip the "Proceed with installation? (Y/N)" confirmation prompt.
    Required when running non-interactively via Invoke-Command.

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
        -CertPfxPath    "C:\certs\osmweb.pfx" `
        -CertPfxPassword "PfxP@ss!" `
        -AdminSubnet    "10.0.1.0/24"

.EXAMPLE
    # Non-interactive remote execution (called from Install-OsmUserWeb-Remote.ps1)
    .\Install-OsmUserWeb.ps1 `
        -PublishPath        C:\Windows\Temp\OsmInstall\publish `
        -TargetOU           "OU=AdminAccounts,DC=contoso,DC=com" `
        -DefaultPassword    "S3cur3P@ss!" `
        -SvcAccountPassword "SvcP@ss!" `
        -CertSelfSigned `
        -AdminSubnet        "10.0.1.0/24" `
        -SkipAdAccount `
        -SkipAdDelegation `
        -Force

.EXAMPLE
    # Remove the installation
    .\Install-OsmUserWeb.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$PublishPath,
    [string]$InstallPath        = 'C:\Services\OsmUserWeb',
    [string]$SvcAccountName     = 'svc-osmweb',
    [string]$SvcAccountPassword,
    [string]$TargetOU           = 'OU=AdminAccounts,DC=opbta,DC=local',
    [string]$GroupName          = 'Domain Admins',
    [string]$DefaultPassword,
    [string]$CertPfxPath        = '',
    [string]$CertPfxPassword,
    [string]$AdminSubnet        = '192.168.0.0/24',
    [int]   $HttpsPort          = 8443,
    [switch]$SkipAdAccount,
    [switch]$SkipAdDelegation,
    [switch]$SkipCertificate,
    [switch]$CertSelfSigned,
    [switch]$SkipFirewall,
    [switch]$Force,
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

function Read-WithDefault {
    # Prompts the user with the current default shown in brackets.
    # Pressing Enter (empty input) accepts the default.
    param([string]$Prompt, [string]$Default)
    $v = (Read-Host "$Prompt [$Default]").Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
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

    # Remove HTTP.sys registrations (try common ports; adjust if non-default was used)
    foreach ($port in @($HttpsPort, 443, 8443)) {
        & netsh http delete urlacl "url=https://+:$port/" 2>$null | Out-Null
        & netsh http delete sslcert "ipport=0.0.0.0:$port" 2>$null | Out-Null
        & netsh http delete sslcert "ipport=[::]:$port" 2>$null | Out-Null
    }
    Write-Ok "HTTP.sys URL ACL and sslcert bindings removed."

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
$script:DomainFQDN       = $null
$script:DomainShort      = $null   # NetBIOS name; used to build SvcFullName
$script:SvcFullName      = $null
$script:SvcPassword      = $null   # plain text - used only in memory during install
$script:PfxPassword      = $null   # plain text - used only during PFX import
$script:CertThumbprint   = $null   # set after cert creation or PFX import

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

    if (-not $SkipAdAccount -or -not $SkipAdDelegation) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            Write-Ok 'ActiveDirectory (RSAT) module loaded.'
        } catch {
            throw 'ActiveDirectory module not found. Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
        }
    } else {
        $null = Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        Write-Ok 'AD steps skipped (-SkipAdAccount and -SkipAdDelegation) — RSAT not required.'
    }

    # -- Step 1: Collect inputs -----------------------------------------------
    Write-Step 'Step 1 . Collecting configuration inputs'

    # Try Get-ADDomain first; fall back to WMI when running in a PS Remoting
    # session where the DC is not directly reachable (double-hop limitation).
    $adDomainObj = $null
    try { $adDomainObj = Get-ADDomain -ErrorAction Stop } catch {}
    if ($adDomainObj) {
        $script:DomainFQDN  = $adDomainObj.DNSRoot
        $script:DomainShort = $adDomainObj.NetBIOSName
    } else {
        $cs = Get-WmiObject Win32_ComputerSystem
        $script:DomainFQDN  = $cs.Domain
        $script:DomainShort = $cs.Domain.Split('.')[0].ToUpper()
    }
    $script:SvcFullName = "$($script:DomainShort)\$SvcAccountName"
    Write-Ok "Detected domain: $($script:DomainFQDN) (NetBIOS: $($script:DomainShort))"

    if (-not $PublishPath) {
        $defaultPublish = Join-Path $PSScriptRoot 'app'
        $PublishPath = if ($Force) { $defaultPublish } else { Read-WithDefault 'Path to dotnet publish output' $defaultPublish }
    }
    if (-not (Test-Path $PublishPath)) {
        throw "Publish path not found: $PublishPath"
    }
    if (-not (Test-Path (Join-Path $PublishPath 'OsmUserWeb.exe'))) {
        throw "OsmUserWeb.exe not found in '$PublishPath'. Run 'dotnet publish' first (see README)."
    }
    Write-Ok "Publish source verified: $PublishPath"

    if (-not $Force) {
        $TargetOU = Read-WithDefault 'Target OU' $TargetOU
    }
    if ($SkipAdAccount -and $SkipAdDelegation) {
        Write-Ok "Target OU (not verified — AD steps skipped): $TargetOU"
    } else {
        try {
            $null = Get-ADOrganizationalUnit -Identity $TargetOU
            Write-Ok "Target OU verified: $TargetOU"
        } catch {
            throw "Target OU not found in AD: $TargetOU"
        }
    }

    if (-not $DefaultPassword) {
        Write-Host ''
        $DefaultPassword = Read-PasswordConfirmed 'Default password for new AD accounts'
    }

    if (-not $SvcAccountPassword) {
        Write-Host ''
        $SvcAccountPassword = Read-PasswordConfirmed "Service account password for $($script:SvcFullName)"
    }
    $script:SvcPassword = $SvcAccountPassword

    # Certificate - collect PFX path or auto-generate.
    # Default: <InstallPath>\certs\osmweb.pfx so the cert lives in the install
    # directory rather than a user-profile temp folder.
    # If no file is found at the default path a self-signed cert is generated.
    if (-not $SkipCertificate -and -not $CertSelfSigned) {
        $defaultCertPath = Join-Path $InstallPath 'certs\osmweb.pfx'

        if (-not $CertPfxPath) {
            if ($Force) {
                $CertPfxPath = $defaultCertPath
            } else {
                Write-Host ''
                $CertPfxPath = Read-WithDefault 'Certificate PFX path' $defaultCertPath
            }
        }

        if (Test-Path $CertPfxPath) {
            Write-Ok "PFX file located: $CertPfxPath"
        } elseif ($CertPfxPath -eq $defaultCertPath) {
            # Accepted the install-dir default but no file present yet — generate self-signed.
            Write-Ok "No certificate found at '$CertPfxPath' — a self-signed certificate will be generated."
            $CertSelfSigned = $true
            $CertPfxPath    = $null
        } else {
            throw "PFX file not found: $CertPfxPath"
        }
    }

    if (-not $SkipCertificate -and -not $CertPfxPath) {
        if ($CertSelfSigned) {
            $certChoice = '2'
        } else {
            Write-Host ''
            Write-Host '  TLS certificate options:' -ForegroundColor DarkGray
            Write-Host '    [1] Use an existing PFX file (certificate + private key)' -ForegroundColor DarkGray
            Write-Host '    [2] Create a self-signed certificate (testing only)'      -ForegroundColor DarkGray
            Write-Host '    [3] Skip TLS for now (configure manually later)'          -ForegroundColor DarkGray
            $certChoice = Read-Host '  Choice (1/2/3)'
        }

        switch ($certChoice.Trim()) {
            '1' {
                $CertPfxPath = Read-NonEmpty 'Path to PFX file'
                if (-not (Test-Path $CertPfxPath)) {
                    throw "PFX file not found: $CertPfxPath"
                }
                Write-Ok "PFX file located: $CertPfxPath"
            }
            '2' {
                Write-Warn 'Self-signed certificate is for TESTING only. Browsers will show a security warning.'

                # Reuse an existing valid self-signed cert for this host rather than
                # creating a new one on every install run.
                $existingSs = Get-ChildItem 'Cert:\LocalMachine\My' |
                    Where-Object {
                        $_.Subject    -eq "CN=$env:COMPUTERNAME" -and
                        $_.Issuer     -eq "CN=$env:COMPUTERNAME" -and   # self-signed
                        $_.NotAfter   -gt (Get-Date).AddDays(30) -and   # not expiring soon
                        $_.HasPrivateKey
                    } |
                    Sort-Object NotAfter -Descending |
                    Select-Object -First 1

                if ($existingSs) {
                    $ssCert = $existingSs
                    Write-Ok "Reusing existing self-signed cert: $($ssCert.Thumbprint) (expires $($ssCert.NotAfter.ToString('yyyy-MM-dd')))"
                } else {
                    # Create a new one - Exportable so the installer can write a PFX backup.
                    $ssCert = New-SelfSignedCertificate `
                        -DnsName           $env:COMPUTERNAME `
                        -CertStoreLocation 'Cert:\LocalMachine\My' `
                        -NotAfter          (Get-Date).AddYears(1) `
                        -KeyAlgorithm      RSA `
                        -KeyLength         2048 `
                        -KeyExportPolicy   Exportable
                    Write-Ok "New self-signed certificate created: $($ssCert.Thumbprint)"
                }

                # Generate a random PFX password for the backup copy.
                $pwBytes = New-Object byte[] 24
                [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($pwBytes)
                $CertPfxPassword = [Convert]::ToBase64String($pwBytes)

                $script:CertThumbprint = $ssCert.Thumbprint
                $CertPfxPath = Join-Path $env:TEMP "osmweb-cert-$($ssCert.Thumbprint).pfx"
                $ssCert | Export-PfxCertificate `
                    -FilePath          $CertPfxPath `
                    -Password          (ConvertTo-SecureString $CertPfxPassword -AsPlainText -Force) `
                    -CryptoAlgorithmOption AES256_SHA256 | Out-Null
            }
            default {
                $SkipCertificate = $true
                Write-Warn 'TLS setup skipped. Follow INSTALL.md step 9 to configure it manually.'
            }
        }
    }

    # If a PFX path is known but no password was given, prompt now
    if (-not $SkipCertificate -and $CertPfxPath -and -not $CertPfxPassword) {
        $CertPfxPassword = Read-PasswordConfirmed 'PFX password'
    }
    $script:PfxPassword = $CertPfxPassword

    # Firewall subnet
    if (-not $SkipFirewall -and -not $Force) {
        Write-Host ''
        $AdminSubnet = Read-WithDefault 'Admin subnet (CIDR)' $AdminSubnet
    }

    Write-Host ''
    Write-Host '  -- Configuration summary -----------------------------------' -ForegroundColor DarkGray
    Write-Host "  Install path   : $InstallPath"
    Write-Host "  Service account: $($script:SvcFullName)"
    Write-Host "  Target OU      : $TargetOU"
    Write-Host "  Group          : $GroupName"
    if ($CertPfxPath)    { Write-Host "  Certificate PFX: $CertPfxPath" }
    if ($AdminSubnet)    { Write-Host "  Admin subnet   : $AdminSubnet" }
    if (-not $Force) {
        Write-Host ''
        $go = Read-Host '  Proceed with installation? (Y/N)'
        if ($go -notin 'Y', 'y') {
            Write-Host 'Aborted. No changes were made.' -ForegroundColor Yellow
            exit 0
        }
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

    if ($SkipAdAccount) {
        Write-Ok "Skipping AD account creation (-SkipAdAccount). Assuming '$SvcAccountName' was provisioned by the calling script."
    } else {
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
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):CC;user");                    Desc = 'Create User objects in OU' }
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):RP;;user",  '/I:S');          Desc = 'Read user properties in OU' }
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):WP;;user",  '/I:S');          Desc = 'Write user properties in OU' }
            @{ Args = @($TargetOU, '/G', "$($script:SvcFullName):CA;Reset Password;user", '/I:S'); Desc = 'Reset password on User objects in OU' }
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

    # HTTP.sys handles TLS at the kernel level; ASP.NET Core only needs to know
    # which URLs to listen on, and that is supplied via ASPNETCORE_URLS in the
    # service registry environment (Step 10) rather than in the JSON config file.
    # No Kestrel or TlsCertificate sections are needed here.

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

    # -- Step 8: HTTP.sys TLS registration -------------------------------------
    if (-not $SkipCertificate -and $CertPfxPath) {
        Write-Step 'Step 8 . Registering certificate with HTTP.sys'

        # For existing PFX (choice [1]): import to LocalMachine\My and get thumbprint.
        # For self-signed (choice [2]): cert is already in LocalMachine\My; thumbprint
        # was captured at creation time in $script:CertThumbprint.
        if (-not $script:CertThumbprint) {
            Write-Host '    Importing PFX to Cert:\LocalMachine\My...'
            $secPfxPw = ConvertTo-SecureString $script:PfxPassword -AsPlainText -Force
            $importedCert = Import-PfxCertificate `
                -FilePath          $CertPfxPath `
                -CertStoreLocation 'Cert:\LocalMachine\My' `
                -Password          $secPfxPw
            $script:CertThumbprint = $importedCert.Thumbprint
            Write-Ok "Certificate imported. Thumbprint: $($script:CertThumbprint)"
        } else {
            Write-Ok "Using pre-imported certificate. Thumbprint: $($script:CertThumbprint)"
        }

        # Keep a copy of the PFX in the install dir for reference / renewal.
        $certsDir       = Join-Path $InstallPath 'certs'
        $pfxInstallPath = Join-Path $certsDir 'osmweb.pfx'
        if (-not (Test-Path $certsDir)) { New-Item -ItemType Directory -Path $certsDir | Out-Null }
        Copy-Item -Path $CertPfxPath -Destination $pfxInstallPath -Force
        $pfxAcl = Get-Acl $pfxInstallPath
        $pfxAcl.SetAccessRuleProtection($true, $false)
        foreach ($t in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
            $pfxAcl.AddAccessRule(
                [System.Security.AccessControl.FileSystemAccessRule]::new($t, 'FullControl', 'Allow'))
        }
        Set-Acl $pfxInstallPath $pfxAcl
        Write-Ok "PFX backed up to $pfxInstallPath (Administrators only)."

        # Remove temp export if it was created by the self-signed path
        if ($CertPfxPath -like "$env:TEMP\osmweb-cert-*") {
            Remove-Item $CertPfxPath -Force -ErrorAction SilentlyContinue
        }

        # HTTP.sys URL reservation - allows svc-osmweb to accept connections on
        # the HTTPS port without running as Administrator.
        & netsh http delete urlacl url="https://+:$HttpsPort/" 2>$null | Out-Null
        $urlOut = & netsh http add urlacl url="https://+:$HttpsPort/" user="$($script:SvcFullName)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "HTTP.sys URL ACL registered for https://+:$HttpsPort/"
        } else {
            Write-Warn "netsh urlacl failed (exit $LASTEXITCODE): $urlOut"
        }

        # HTTP.sys SSL cert binding - associates the certificate with the port.
        # HTTP.sys (SYSTEM, kernel mode) reads the cert from the machine store;
        # svc-osmweb never touches the private key.
        $appId = "{$([System.Guid]::NewGuid().ToString())}"
        foreach ($ip in @('0.0.0.0', '[::]')) {
            & netsh http delete sslcert "ipport=$ip`:$HttpsPort" 2>$null | Out-Null
            $sslOut = & netsh http add sslcert "ipport=$ip`:$HttpsPort" `
                          "certhash=$($script:CertThumbprint)" `
                          "appid=$appId" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "HTTP.sys sslcert binding registered for $ip`:$HttpsPort"
            } else {
                Write-Warn "netsh sslcert $ip failed (exit $LASTEXITCODE): $sslOut"
            }
        }
    } else {
        Write-Step 'Step 8 . Skipping HTTP.sys TLS registration (no cert configured)'
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

    $regPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"

    # ASPNETCORE_URLS configures the HTTP.sys URL prefixes.
    # HTTP endpoint is always present; HTTPS endpoint is added when a cert is configured.
    $urls = "http://localhost:5150"
    if (-not $SkipCertificate -and $script:CertThumbprint) {
        $urls += ";https://+:$HttpsPort"
    }

    New-ItemProperty -Path $regPath -Name 'Environment' -PropertyType MultiString -Force `
        -Value @(
            'ASPNETCORE_ENVIRONMENT=Production',
            "AdSettings__DefaultPassword=$DefaultPassword",
            "ASPNETCORE_URLS=$urls"
        ) | Out-Null
    Write-Ok "Secrets and URL config written to HKLM service registry key."
    Write-Ok "ASPNETCORE_URLS=$urls"

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

        # Verify HTTP.sys actually opened the port — SCM RUNNING only means the process
        # started, not that the web listener is up.  Give HTTP.sys a moment to register.
        if (-not $SkipCertificate -and $script:CertThumbprint) {
            Start-Sleep -Seconds 3
            $curlOut = & curl.exe -k -s -o $null -w '%{http_code}' "https://localhost:$HttpsPort/" 2>&1
            if ($curlOut -eq '200') {
                Write-Ok "HTTPS connectivity verified: https://localhost:$HttpsPort/ -> HTTP 200"
            } else {
                Write-Warn "HTTPS connectivity check failed (curl returned: '$curlOut')."
                Write-Warn "Port $HttpsPort is not responding. The service may have crashed after starting."
                Write-Host ''
                Write-Host '  Recent application event log entries:' -ForegroundColor Yellow
                Get-EventLog -LogName Application -Source $ServiceName -Newest 10 `
                    -ErrorAction SilentlyContinue |
                    Select-Object TimeGenerated, EntryType, Message | Format-List
                Write-Host '  Recent HTTP.sys event log entries:' -ForegroundColor Yellow
                Get-EventLog -LogName System -Source 'HTTP' -Newest 5 `
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
    if ($CertPfxPath) {
    $pfxDest = Join-Path $InstallPath 'certs\osmweb.pfx'
    Write-Host "  |  Certificate  : $pfxDest"                               -ForegroundColor Green
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
