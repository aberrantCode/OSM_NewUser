# Production Deployment Guide — OsmUserWeb

This guide walks through deploying OsmUserWeb as a hardened Windows Service. It follows a defence-in-depth approach: dedicated low-privilege service account, delegated-only AD permissions, TLS, and network-layer access control.

> **Automated installer available** — [`Install-OsmUserWeb.ps1`](Install-OsmUserWeb.ps1) automates every step in this document. Run it from an elevated PowerShell session on the target server. Refer to this guide for background, manual steps, and troubleshooting.
>
> **To uninstall** — [`Uninstall-OsmUserWeb.ps1`](Uninstall-OsmUserWeb.ps1) stops and removes the service, HTTP.sys registrations, firewall rules, and application files. Pass `-RemoveServiceAccount` and/or `-RemoveCertificate` to also clean up the AD account and TLS certificate.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Server Prerequisites](#2-server-prerequisites)
3. [Create the Service Account](#3-create-the-service-account)
4. [Delegate Active Directory Permissions](#4-delegate-active-directory-permissions)
5. [Install the .NET 9 ASP.NET Core Hosting Bundle](#5-install-the-net-9-aspnet-core-hosting-bundle)
6. [Publish the Application](#6-publish-the-application)
7. [Deploy Application Files](#7-deploy-application-files)
8. [Configure Production Settings](#8-configure-production-settings)
9. [Configure TLS / HTTPS](#9-configure-tls--https)
10. [Install as a Windows Service](#10-install-as-a-windows-service)
11. [Restrict Network Access](#11-restrict-network-access)
12. [Optional: IIS as a Reverse Proxy](#12-optional-iis-as-a-reverse-proxy)
13. [Verify the Deployment](#13-verify-the-deployment)
14. [Maintenance](#14-maintenance)

---

## 1. Architecture Overview

```
[Admin workstation]
        │  HTTPS 8443
        ▼
[OsmUserWeb server]  ──LDAP──→  [Domain Controller]
  Windows Service (HTTP.sys)
  svc-osmweb account
  C:\Services\OsmUserWeb
```

The web server sits on your admin network segment. Only authorised admin workstations can reach it. TLS is handled by **HTTP.sys** (the Windows kernel HTTP driver, running as SYSTEM) — the `svc-osmweb` service account never touches the certificate private key. The service account authenticates to Active Directory using delegated permissions limited to creating users in the target OU and adding them to the target group.

---

## 2. Server Prerequisites

| Requirement | Minimum | Notes |
|---|---|---|
| OS | Windows Server 2019 or 2022 | Must be domain-joined |
| RAM | 512 MB available | HTTP.sys + AD queries are lightweight |
| Disk | 500 MB | Application, logs, and .NET runtime |
| Network | Reachable on port 8443 from admin workstations | Firewall rule added in step 11 |
| .NET 9 Hosting Bundle | See step 5 | Do **not** install the full SDK on production servers |

> **Do not** deploy on a Domain Controller. Run the service on a separate member server.

---

## 2a. Provision a Proxmox VM (optional)

If you need to create a dedicated VM in Proxmox to host the OsmUserWeb application, the repository includes a PowerShell helper that creates a new QEMU VM named `AC-SVR1` using the Proxmox REST API.

This script is intentionally conservative and designed for environments where:

- You have a Proxmox API token with sufficient permissions to create and start VMs (recommended), or credentials to authenticate.
- A Windows Nano Server ISO (or other Windows installer ISO) is already uploaded to a Proxmox storage (for example `local:iso/WindowsNano.iso`).
- You know the target Proxmox node name, storage names (for ISO and disk), and the VM ID you want to use.

The script is located at `src/PwshScript/Create-Proxmox-AC-SVR1.ps1`. It performs the following at a high level:

- Authenticates to the Proxmox API (API token recommended).
- Creates a new QEMU VM with sensible defaults (2 cores, 2 GB RAM, 32 GB disk, virtio/scsi hardware set).
- Attaches the specified ISO as a CD-ROM and configures the VM to boot from it.
- Starts the VM and returns the proxmox task UPID for tracking.

Assumptions and notes
- The script cannot install Windows or configure in-guest settings — it only provisions the VM and boots the installer ISO. You must complete the Windows Nano installation interactively or automate it using your existing imaging process.
- You must adjust the variables in the script for your Proxmox host, node name, storage identifiers, ISO filename, and desired VM ID.
- For production, create a Proxmox API token (Datacenter → Permissions → API Tokens) and prefer that over username/password. The script supports both.

Usage example (PowerShell):

```powershell
# From a PowerShell prompt on an admin workstation
cd src\PwshScript
.\Create-Proxmox-AC-SVR1.ps1 `
  -ProxmoxHost 'proxmox.example.local' `
  -Node 'pve-node1' `
  -VmId 601 `
  -VmName 'AC-SVR1' `
  -IsoStorage 'local' `
  -IsoFile 'WindowsNano.iso' `
  -DiskStorage 'local-lvm' `
  -ApiTokenId 'apiuser!tokenid' `
  -ApiTokenSecret (Read-Host -AsSecureString 'Proxmox API token')
```

The script prints the Proxmox API response and the task UPID; track progress in the Proxmox UI or via API.

Contract (what the script does)
- Inputs: Proxmox host, node name, VM id, VM name, ISO/storage names, API auth (token or username/password).
- Outputs: Creates a VM on the specified node, attaches the ISO, starts the VM, and returns the task UPID.
- Errors: Fails if authentication fails, if the VM ID is already used, or if the specified storages/ISO are not found.

Edge cases
- Existing VM with same ID: the script will abort if the VM ID already exists.
- Missing ISO/storage name: the create call will fail — verify storage paths in Proxmox first.
- Network/bridge name mismatch: ensure the `-Bridge` value matches a bridge on the target node (default `vmbr0`).

Security
- Do not store plaintext API tokens in source control. Use parameter prompts or a secrets manager.

---

---

## 3. Create the Service Account

A dedicated domain account limits the blast radius of any compromise and keeps AD audit logs attributable to the service.

### 3a. Create the account

Run the following on a DC or any workstation with RSAT installed. Replace `opbta` and `opbta.local` throughout this guide.

```powershell
New-ADUser `
    -Name                 "svc-osmweb" `
    -SamAccountName       "svc-osmweb" `
    -UserPrincipalName    "svc-osmweb@opbta.local" `
    -AccountPassword      (Read-Host -AsSecureString "Service account password") `
    -Enabled              $true `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Description          "OsmUserWeb Windows Service account — do not add to any admin groups"
```

### 3b. Grant "Log on as a service" on the application server

Run this **on the application server** as a local Administrator.

```powershell
# Export current policy, append the right, re-import
$account = "opbta\svc-osmweb"
$tmpCfg  = "$env:TEMP\secpol_osmweb.cfg"

secedit /export /cfg $tmpCfg /quiet
$content = Get-Content $tmpCfg
$existing = $content | Where-Object { $_ -match "SeServiceLogonRight" }

if ($existing) {
    $content = $content -replace "SeServiceLogonRight = (.*)", "SeServiceLogonRight = `$1,*$((Get-ADUser svc-osmweb).SID)"
} else {
    $content += "`r`n[Privilege Rights]`r`nSeServiceLogonRight = *$((Get-ADUser svc-osmweb).SID)"
}

$content | Set-Content $tmpCfg
secedit /configure /cfg $tmpCfg /db secedit.sdb /quiet
Remove-Item $tmpCfg
```

> **Alternative (GUI):** Open **Local Security Policy → Local Policies → User Rights Assignment → Log on as a service** and add `opbta\svc-osmweb`.

---

## 4. Delegate Active Directory Permissions

The service account must be able to:

- Read the target OU (to verify it exists)
- Create and write User objects in the target OU
- Write the `member` attribute on the target group

It must **not** be a member of Domain Admins or any other privileged group.

### 4a. Delegate on the target OU

#### GUI (Delegation of Control Wizard)

1. Open **Active Directory Users and Computers**
2. Right-click the target OU → **Delegate Control**
3. Add `opbta\svc-osmweb`
4. Choose **Create a custom task to delegate**
5. Select **Only the following objects → User objects**, check **Create selected objects in this folder**
6. Check **General**, **Property-specific**, then select: **Read all properties**, **Write all properties**, **Reset password**

#### PowerShell equivalent (`dsacls`)

```powershell
$ouDN     = "OU=AdminAccounts,DC=opbta,DC=local"
$identity = "opbta\svc-osmweb"

# Create User objects in the OU
dsacls $ouDN /G "${identity}:CC;user"

# Read all properties on User objects in the OU (/I:S required when specifying an inherited object type)
dsacls $ouDN /G "${identity}:RP;;user" /I:S

# Write all properties on User objects in the OU
dsacls $ouDN /G "${identity}:WP;;user" /I:S

# Reset password on User objects in the OU (required for New-ADUser)
dsacls $ouDN /G "${identity}:CA;Reset Password;user" /I:S
```

### 4b. Grant "Write Members" on the target group

```powershell
$groupDN  = "CN=Domain Admins,CN=Users,DC=opbta,DC=local"
$identity = "opbta\svc-osmweb"

# Allow writing the member attribute (add/remove members)
dsacls $groupDN /G "${identity}:WP;member"
```

> **Security note:** Write access to the `member` attribute of Domain Admins is a high-privilege delegation. If your change-management process requires it, consider targeting a staging group first and using a scheduled task to sync membership to Domain Admins. Document this delegation in your change record.

### 4c. Verify the delegation

```powershell
# Confirm svc-osmweb is NOT in any privileged groups
Get-ADPrincipalGroupMembership svc-osmweb | Select-Object Name
# Expected: Domain Users (and nothing else)
```

---

## 5. Install the .NET 9 ASP.NET Core Hosting Bundle

Install the **Hosting Bundle** — not the full SDK — on the production server. The Hosting Bundle includes the ASP.NET Core runtime and the IIS integration module.

```powershell
# Option A: winget (recommended)
winget install --id Microsoft.DotNet.AspNetCore.9 `
    --source winget `
    --accept-package-agreements `
    --accept-source-agreements

# Option B: direct download
# Grab the Hosting Bundle installer from https://dotnet.microsoft.com/download/dotnet/9
# and run: dotnet-hosting-9.x.x-win.exe /install /quiet /norestart
```

Verify the runtime is present:

```powershell
dotnet --list-runtimes | Where-Object { $_ -match "^Microsoft.AspNetCore.App 9\." }
```

---

## 6. Publish the Application

Run this on your **build machine**, not the production server.

```powershell
cd src/DotNetWebServer

dotnet publish OsmUserWeb.csproj `
    --configuration Release `
    --runtime       win-x64 `
    --self-contained false `
    --output        ./publish
```

The `publish/` folder is the complete deployment artifact.

> Use `--self-contained true` if you prefer to bundle the runtime and skip step 5. This increases the deployment size (~90 MB) but eliminates the runtime dependency.

---

## 7. Deploy Application Files

### 7a. Create the deployment directory on the server

```powershell
New-Item -ItemType Directory -Path "C:\Services\OsmUserWeb"
New-Item -ItemType Directory -Path "C:\Services\OsmUserWeb\logs"
```

### 7b. Lock down directory permissions

```powershell
$svcPath = "C:\Services\OsmUserWeb"
$account = "opbta\svc-osmweb"

# Remove inherited permissions and apply explicit rules
$acl = Get-Acl $svcPath
$acl.SetAccessRuleProtection($true, $false)

# SYSTEM and Administrators: full control
foreach ($trustee in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $trustee, "FullControl",
        "ContainerInherit,ObjectInherit", "None", "Allow")))
}

# Service account: read and execute only (cannot modify its own binaries)
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $account, "ReadAndExecute",
    "ContainerInherit,ObjectInherit", "None", "Allow")))

Set-Acl $svcPath $acl

# Service account: Modify on logs only
$logsAcl = Get-Acl "$svcPath\logs"
$logsAcl.SetAccessRuleProtection($true, $false)
foreach ($trustee in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
    $logsAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $trustee, "FullControl",
        "ContainerInherit,ObjectInherit", "None", "Allow")))
}
$logsAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $account, "Modify",
    "ContainerInherit,ObjectInherit", "None", "Allow")))
Set-Acl "$svcPath\logs" $logsAcl
```

### 7c. Copy the published output

```powershell
Copy-Item -Path ".\publish\*" -Destination "C:\Services\OsmUserWeb" -Recurse -Force
```

---

## 8. Configure Production Settings

### 8a. Create appsettings.Production.json

Create `C:\Services\OsmUserWeb\appsettings.Production.json` with non-secret overrides. This file is environment-specific and is **not** shipped with the published output.

```json
{
  "Logging": {
    "LogLevel": {
      "Default":              "Warning",
      "OsmUserWeb":           "Information",
      "Microsoft.AspNetCore": "Warning"
    },
    "EventLog": {
      "SourceName": "OsmUserWeb",
      "LogName":    "Application"
    }
  },
  "AdSettings": {
    "TargetOU":  "OU=AdminAccounts,DC=opbta,DC=local",
    "GroupName": "Domain Admins"
  }
}
```

> Do **not** add `DefaultPassword` to this file. It will be injected as a service environment variable in step 10c.

### 8b. Protect the configuration files

> **Prerequisite:** Complete step 8a first. `appsettings.Production.json` must exist before this script runs.

```powershell
# Deny read access to Everyone except Administrators and SYSTEM
$cfgFiles = @(
    "C:\Services\OsmUserWeb\appsettings.json",
    "C:\Services\OsmUserWeb\appsettings.Production.json"
)
foreach ($file in $cfgFiles) {
    if (-not (Test-Path $file)) {
        Write-Warning "Skipping '$file' — file does not exist. Complete step 8a first."
        continue
    }
    $acl = Get-Acl $file
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($trustee in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $trustee, "FullControl", "Allow")))
    }
    # Service account: read-only (needs to read config at startup)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        "opbta\svc-osmweb", "Read", "Allow")))
    Set-Acl $file $acl
}
```

---

## 9. Configure TLS / HTTPS

Transmitting AD passwords over plain HTTP is unacceptable. HTTPS is mandatory for any non-loopback deployment.

### 9a. Obtain a certificate

| Method | When to use |
|---|---|
| **Internal CA (recommended)** | Domain-joined server — request a certificate from your organisation's PKI |
| **win-acme (Let's Encrypt)** | Internet-accessible server with a publicly resolvable DNS name |
| **Self-signed (testing only)** | Browsers will show a security warning; never use in production |

Follow the section that matches your environment. All three methods end with the certificate in the **LocalMachine → Personal (My)** store and a thumbprint you will paste into later steps.

---

#### Method 1: Internal CA (recommended)

**Option A — Request directly from PowerShell (enterprise CA)**

Run this on the application server. The server must be able to reach an enterprise CA (i.e. domain-joined with Certificate Services deployed).

```powershell
$hostname = $env:COMPUTERNAME          # or use the server's FQDN, e.g. "osmweb.yourdomain.com"

$cert = Get-Certificate `
    -Template        "WebServer" `
    -SubjectName     "CN=$hostname" `
    -DnsName         $hostname `
    -CertStoreLocation "Cert:\LocalMachine\My"

$cert.Certificate | Select-Object Subject, Thumbprint, NotAfter
```

> If the `WebServer` template is not available in your environment, ask your PKI administrator for the correct template name (`certutil -catemplates` lists available templates).

**Option B — Import a PFX delivered by your PKI team**

```powershell
$pfxPassword = Read-Host -AsSecureString "PFX password"
Import-PfxCertificate `
    -FilePath          "C:\Temp\osmweb.pfx" `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -Password          $pfxPassword

# Note the thumbprint — you will need it in steps 9b and 9c
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -match "osmweb" } |
    Select-Object Subject, Thumbprint, NotAfter
```

---

#### Method 2: win-acme (Let's Encrypt)

Use this only if the server has a **publicly resolvable DNS name** and **inbound port 80** is reachable from the internet for the ACME HTTP-01 challenge.

1. Download the latest win-acme release from [https://www.win-acme.com](https://www.win-acme.com) and extract it to `C:\Tools\win-acme`.

2. Run win-acme from an elevated PowerShell session:

```powershell
Set-Location "C:\Tools\win-acme"
.\wacs.exe
```

3. Follow the interactive prompts:
   - Choose **N** — Create certificate (default settings)
   - Select **1** — Single binding of an IIS site, **or** choose the manual option and enter the hostname
   - When asked for the store, choose **Certificate Store (Local Machine)**
   - Accept the Let's Encrypt subscriber agreement

4. win-acme installs the certificate into `Cert:\LocalMachine\My` and schedules automatic renewal via a Windows Scheduled Task.

5. Note the thumbprint:

```powershell
Get-ChildItem Cert:\LocalMachine\My |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1 Subject, Thumbprint, NotAfter
```

> Because win-acme renews certificates automatically (every ~60 days), you must re-register the new thumbprint with HTTP.sys on each renewal (see the **Certificate renewal** section in step 14). Configure a win-acme renewal script to run those `netsh` commands automatically so the service is never interrupted.

---

#### Method 3: Self-signed (testing only)

> **Warning:** Browsers will display a security warning. Do not use this in production.

```powershell
$hostname = $env:COMPUTERNAME   # or the server's FQDN

$cert = New-SelfSignedCertificate `
    -DnsName           $hostname `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -NotAfter          (Get-Date).AddYears(1) `
    -KeyUsage          DigitalSignature, KeyEncipherment `
    -TextExtension     @("2.5.29.37={text}1.3.6.1.5.5.7.3.1")   # Server Authentication EKU

$cert | Select-Object Subject, Thumbprint, NotAfter
```

To suppress the browser warning on admin workstations, export the certificate and import it into each workstation's **Trusted Root Certification Authorities** store:

```powershell
# Export the public certificate (no private key)
Export-Certificate `
    -Cert  "Cert:\LocalMachine\My\$($cert.Thumbprint)" `
    -FilePath "C:\Temp\osmweb-selfsigned.cer"

# On each admin workstation (elevated):
Import-Certificate `
    -FilePath          "C:\Temp\osmweb-selfsigned.cer" `
    -CertStoreLocation "Cert:\LocalMachine\Root"
```

---

### 9b. Register the certificate with HTTP.sys

HTTP.sys handles TLS termination in kernel mode (running as SYSTEM). The `svc-osmweb` service account never needs access to the certificate private key. You register the certificate and grant `svc-osmweb` permission to accept connections via two `netsh` commands.

```powershell
$thumb     = "PASTE_YOUR_THUMBPRINT_HERE"   # from step 9a
$httpsPort = 8443
$svcAcct   = "opbta\svc-osmweb"
$appId     = "{$([System.Guid]::NewGuid().ToString())}"

# Grant svc-osmweb permission to accept connections on the HTTPS port
netsh http add urlacl "url=https://+:$httpsPort/" "user=$svcAcct"

# Register the certificate with HTTP.sys for TLS (IPv4 and IPv6)
foreach ($ip in @('0.0.0.0', '[::]')) {
    netsh http add sslcert "ipport=${ip}:$httpsPort" `
        "certhash=$thumb" "appid=$appId"
}
```

Verify the registrations:

```powershell
netsh http show urlacl  "url=https://+:$httpsPort/"
netsh http show sslcert "ipport=0.0.0.0:$httpsPort"
netsh http show sslcert "ipport=[::]:$httpsPort"
```

> **No private-key ACL required.** HTTP.sys reads the certificate as SYSTEM. Unlike the Kestrel approach, `svc-osmweb` does not need `Read` access to the private key file in `%ProgramData%\Microsoft\Crypto\RSA\MachineKeys`.

---

## 10. Install as a Windows Service

### 10a. Register the service

```powershell
$binPath  = "C:\Services\OsmUserWeb\OsmUserWeb.exe"
$svcAcct  = "opbta\svc-osmweb"
$svcPass  = Read-Host -AsSecureString "Service account password"
$passPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($svcPass))

sc.exe create OsmUserWeb `
    binPath=     $binPath `
    obj=         $svcAcct `
    password=    $passPlain `
    start=       auto `
    DisplayName= "OSM User Web"

sc.exe description OsmUserWeb `
    "ASP.NET Core web UI for creating numbered Active Directory admin accounts."
```

### 10b. Configure automatic restart on failure

```powershell
sc.exe failure OsmUserWeb reset= 86400 actions= restart/5000/restart/10000/restart/30000
```

This restarts the service after 5 s on the first failure, 10 s on the second, 30 s on subsequent failures, and resets the failure counter after 24 hours.

### 10c. Inject secrets as service environment variables

Service environment variables are stored in the Windows registry as a `REG_MULTI_SZ` value under the service key. They are readable only by Administrators and SYSTEM — never exposed to normal users or the application filesystem.

```powershell
$httpsPort = 8443   # must match step 9b

New-ItemProperty `
    -Path         "HKLM:\SYSTEM\CurrentControlSet\Services\OsmUserWeb" `
    -Name         "Environment" `
    -PropertyType MultiString `
    -Value        @(
        "ASPNETCORE_ENVIRONMENT=Production",
        "AdSettings__DefaultPassword=YourActualP@ssw0rd",
        "ASPNETCORE_URLS=http://localhost:5150;https://+:$httpsPort"
    ) `
    -Force
```

`ASPNETCORE_URLS` is required because HTTP.sys ignores `Kestrel:Endpoints` in `appsettings.json`. The `http://localhost:5150` binding allows health checks on the loopback interface without going through TLS.

> For higher security, consider fetching the password at startup from **Windows Credential Manager** (`cmdkey`) or **Azure Key Vault** via a Managed Identity and injecting it through a custom `IConfigurationProvider`, so the plaintext password never touches the registry.

### 10d. Start the service and confirm it is running

```powershell
sc.exe start OsmUserWeb

# Poll until running (or timeout after 30 s)
$deadline = (Get-Date).AddSeconds(30)
do {
    $state = (sc.exe query OsmUserWeb | Select-String "STATE").ToString()
    Start-Sleep -Milliseconds 500
} until ($state -match "RUNNING" -or (Get-Date) -gt $deadline)

sc.exe query OsmUserWeb   # Expected: STATE: 4 RUNNING
```

Check the Windows Event Log for the startup entry:

```powershell
Get-EventLog -LogName Application -Source OsmUserWeb -Newest 5
```

---

## 11. Restrict Network Access

Because this tool creates privileged AD accounts, access must be limited to authorised admin workstations only. Apply restrictions at both the host firewall and the network perimeter.

### 11a. Windows Defender Firewall

```powershell
$adminSubnet = "10.0.1.0/24"   # Replace with your admin VLAN/subnet
$httpsPort   = 8443

# Allow HTTPS from admin workstations
New-NetFirewallRule `
    -DisplayName   "OsmUserWeb — allow HTTPS from admin subnet" `
    -Direction     Inbound `
    -Protocol      TCP `
    -LocalPort     $httpsPort `
    -RemoteAddress $adminSubnet `
    -Action        Allow

# Block all other inbound traffic on the HTTPS port
New-NetFirewallRule `
    -DisplayName   "OsmUserWeb — block HTTPS from all others" `
    -Direction     Inbound `
    -Protocol      TCP `
    -LocalPort     $httpsPort `
    -Action        Block
```

> Rule evaluation order: Windows Firewall processes **Allow** rules before **Block** rules at the same priority, but the admin-allow rule must be created first so it is matched before the block-all rule. Verify with `Get-NetFirewallRule -DisplayName "OsmUserWeb*"`.

### 11b. Network perimeter (router / switch ACL)

In addition to the host firewall, configure an ACL on the router or managed switch to allow only packets sourced from admin workstation IPs to reach port 443 on the OsmUserWeb server. Host firewalls alone are insufficient because they can be disabled by a local administrator.

### 11c. Recommended network topology

```
Internet / corporate LAN
        │
   [Perimeter firewall — block all to OsmUserWeb]
        │
   Admin VLAN (10.0.1.0/24)
        │
   [OsmUserWeb server — Windows Firewall allows 10.0.1.0/24 only]
        │
   [Domain Controller]
```

---

## 12. Optional: IIS as a Reverse Proxy

OsmUserWeb uses HTTP.sys directly, so IIS is **not required** for TLS — the certificate is registered with HTTP.sys via `netsh` (step 9b). If your organisation's policy requires IIS as the public-facing listener for HTTP/2, WAF integration, or centralised site management, you can configure IIS to reverse-proxy to the HTTP.sys process.

### 12a. Install IIS and the Application Request Routing module

```powershell
Install-WindowsFeature Web-Server, Web-Asp-Net45 -IncludeManagementTools

# Install ARR 3.0 and URL Rewrite 2.1 via WebPI or direct MSI:
# https://www.iis.net/downloads/microsoft/application-request-routing
# https://www.iis.net/downloads/microsoft/url-rewrite
```

### 12b. Create a web.config alongside the executable

`C:\Services\OsmUserWeb\web.config`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="aspNetCore" path="*" verb="*"
           modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    <aspNetCore
        processPath=".\OsmUserWeb.exe"
        stdoutLogEnabled="false"
        stdoutLogFile=".\logs\stdout"
        hostingModel="OutOfProcess" />
  </system.webServer>
</configuration>
```

### 12c. IIS TLS termination

When IIS handles TLS termination, bind the certificate to the IIS site and update `ASPNETCORE_URLS` in the service registry environment (step 10c) to listen on `http://localhost:5150` only — remove the `https://+:8443` prefix. The HTTP.sys `netsh` registrations from step 9b are also no longer needed.

---

## 13. Verify the Deployment

Complete this checklist after deploying. Do not sign off until every item passes.

**Service health**
- [ ] `sc.exe query OsmUserWeb` shows `STATE: 4 RUNNING`
- [ ] Windows Event Log → Application contains an `OsmUserWeb` `Information` entry for startup
- [ ] No `Error` or `Warning` entries in the Event Log immediately after start

**TLS and access**
- [ ] `https://<server>:8443/` loads the UI in a browser from an admin workstation
- [ ] The TLS certificate is valid (no browser warning; correct hostname; `NotAfter` is in the future)
- [ ] Browsing to `http://<server>:8443/` is either blocked or redirected to HTTPS
- [ ] Attempting to reach the URL from a non-admin IP is blocked at the firewall

**Functional**
- [ ] The **Preview** button returns the correct next username, OU, and group
- [ ] Creating a test account (e.g., `BaseName = testacct`) succeeds end-to-end
- [ ] The test account appears in AD Users and Computers in the correct OU
- [ ] All account properties match the expected values (Enabled, PasswordNeverExpires, etc.)
- [ ] The test account is a member of the configured group
- [ ] Running **Preview** again increments the number (e.g., `testacct1` → `testacct2`)

**Security**
- [ ] The service account `svc-osmweb` is **not** a member of Domain Admins or any other privileged group
- [ ] `appsettings.json` and `appsettings.Production.json` on the server do **not** contain the production password
- [ ] `C:\Services\OsmUserWeb` is not writable by `svc-osmweb` (except `logs\`)
- [ ] `netsh http show sslcert ipport=0.0.0.0:8443` shows the expected certificate thumbprint

---

## 14. Maintenance

### Updating the application

```powershell
# 1. Build and publish on the build machine
dotnet publish OsmUserWeb.csproj `
    --configuration Release `
    --runtime win-x64 `
    --self-contained false `
    --output ./publish

# 2. Copy to the server (SFTP, robocopy, or your deployment tooling)
#    Then, on the server:

# 3. Stop the service
sc.exe stop OsmUserWeb

# 4. Back up the current deployment
Rename-Item "C:\Services\OsmUserWeb" "C:\Services\OsmUserWeb.bak"

# 5. Create fresh directory and copy new files
New-Item -ItemType Directory "C:\Services\OsmUserWeb"
Copy-Item ".\publish\*" "C:\Services\OsmUserWeb" -Recurse

# 6. Restore the environment-specific config (not shipped in publish output)
Copy-Item "C:\Services\OsmUserWeb.bak\appsettings.Production.json" `
          "C:\Services\OsmUserWeb\"

# 7. Re-apply directory permissions (step 7b)

# 8. Start the service and verify
sc.exe start OsmUserWeb
sc.exe query OsmUserWeb

# 9. Once verified, remove the backup
Remove-Item "C:\Services\OsmUserWeb.bak" -Recurse -Force
```

### Log management

Structured logs are written to the Windows Event Log (`Application` source: `OsmUserWeb`). By default ASP.NET Core does not write to files unless configured with a file sink.

To view recent log entries:

```powershell
Get-EventLog -LogName Application -Source OsmUserWeb -Newest 50 |
    Select-Object TimeGenerated, EntryType, Message |
    Format-List
```

To forward logs to a SIEM or centralise retention, configure **Windows Event Forwarding (WEF)** or install an agent (Splunk UF, nxlog, Elastic Agent) pointing at the Application event log.

### Certificate renewal

When the TLS certificate is renewed:

1. Import the new certificate into `Cert:\LocalMachine\My`
2. Re-register the new thumbprint with HTTP.sys (no service restart needed for the re-registration itself):

```powershell
$newThumb  = "NEW_THUMBPRINT_HERE"
$httpsPort = 8443
$appId     = "{$([System.Guid]::NewGuid().ToString())}"

# Replace the old SSL cert binding
foreach ($ip in @('0.0.0.0', '[::]')) {
    netsh http delete sslcert "ipport=${ip}:$httpsPort"
    netsh http add sslcert "ipport=${ip}:$httpsPort" `
        "certhash=$newThumb" "appid=$appId"
}
```

3. Restart the service so ASP.NET Core picks up the new cert from HTTP.sys:

```powershell
sc.exe stop  OsmUserWeb
sc.exe start OsmUserWeb
sc.exe query OsmUserWeb
```

> No changes to `appsettings.Production.json` are needed — HTTP.sys owns the certificate binding, not the application config.

If using **win-acme** for automated renewal, configure a renewal script to run the `netsh` commands above automatically.

### Service account password rotation

```powershell
# 1. Reset the password in AD
Set-ADAccountPassword svc-osmweb -Reset `
    -NewPassword (Read-Host -AsSecureString "New password")

# 2. Update the service registration
sc.exe config OsmUserWeb password= "NewPlaintextPassword"

# 3. Restart the service
sc.exe stop  OsmUserWeb
sc.exe start OsmUserWeb
sc.exe query OsmUserWeb
```

### Removing the service

Use the uninstall script for a complete, safe removal. It discovers the HTTPS port from the registry, removes the Windows Service, HTTP.sys URL ACL and SSL cert bindings, firewall rules, and application files.

```powershell
# Minimal removal (service, HTTP.sys, firewall, files)
.\Uninstall-OsmUserWeb.ps1

# Also remove the svc-osmweb AD account and the TLS certificate from the store
.\Uninstall-OsmUserWeb.ps1 -RemoveServiceAccount -RemoveCertificate
```

See [`Uninstall-OsmUserWeb.ps1`](Uninstall-OsmUserWeb.ps1) for the full parameter reference.
