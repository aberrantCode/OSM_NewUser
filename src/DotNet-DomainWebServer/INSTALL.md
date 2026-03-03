# Production Deployment Guide — OsmUserWeb

This document provides a concise, actionable installation guide for OsmUserWeb.
It is organised as:

- High-level installation steps
- Detailed implementation of each step (GUI and PowerShell) so operators can choose their preferred approach
- A summary of the repository scripts that automate the steps
- Uninstall instructions and the uninstall script

Automated installer: `Install-OsmUserWeb.ps1` (see the Scripts section).

## High-level steps

1. Prepare the server and prerequisites (OS, .NET hosting bundle, networking)
2. Create and harden the service account in Active Directory
3. Delegate minimal AD permissions to the service account
4. Publish the application on the build machine and copy the `publish/` output to the server
5. Configure TLS: obtain a certificate and bind it to HTTP.sys
6. Deploy files, set ACLs, and create service configuration (environment variables)
7. Install and start the Windows Service (OsmUserWeb)
8. Restrict network access (host firewall and perimeter)
9. Verify service health, TLS, and functionality

## Detailed steps (each step: GUI and PowerShell)

### 1. Prepare server and prerequisites

Manual (GUI):
- Ensure the server is domain-joined, patched, and has needed disk/CPU resources. Install IIS if your org requires it.

PowerShell:
```powershell
# Install .NET Hosting Bundle (optionally via winget) and verify runtime
winget install --id Microsoft.DotNet.AspNetCore.9 --accept-package-agreements --accept-source-agreements
dotnet --list-runtimes | Where-Object { $_ -match "^Microsoft.AspNetCore.App 9\." }
```

### 2. Create and harden the service account

GUI:
- Use Active Directory Users and Computers → New User. Create `svc-osmweb` with a strong password and appropriate description.

PowerShell:
```powershell
New-ADUser -Name "svc-osmweb" -SamAccountName "svc-osmweb" -UserPrincipalName "svc-osmweb@YOURDOMAIN" \
  -AccountPassword (Read-Host -AsSecureString "Service account password") -Enabled $true -CannotChangePassword $true
```

Grant "Log on as a service"

GUI: Local Security Policy → Local Policies → User Rights Assignment → Log on as a service → add `YOURDOMAIN\svc-osmweb`.

PowerShell (example approach using secedit export/import):
```powershell
# Run on the application server as Administrator; export, modify, and re-import the secpol file to add the svc account SID to SeServiceLogonRight.
```

### 3. Delegate AD permissions (create users, set group membership)

GUI (Delegation Wizard):
1. Open Active Directory Users and Computers
2. Right-click the target OU → Delegate Control
3. Add `svc-osmweb` → Create a custom task → select `User` objects → grant Create, Read, Write, Reset Password as required

PowerShell / dsacls:
```powershell
$ouDN     = "OU=AdminAccounts,DC=example,DC=com"
$identity = "EXAMPLE\svc-osmweb"
dsacls $ouDN /G "${identity}:CC;user"
dsacls $ouDN /G "${identity}:RP;;user" /I:S
dsacls $ouDN /G "${identity}:WP;;user" /I:S
dsacls $ouDN /G "${identity}:CA;Reset Password;user" /I:S

# Grant write member on the target group
$groupDN = 'CN=TargetGroup,CN=Users,DC=example,DC=com'
dsacls $groupDN /G "${identity}:WP;member"
```

### 4. Publish the application (build machine)

PowerShell (build machine):
```powershell
cd src/DotNet-DomainWebServer
dotnet publish OsmUserWeb.csproj --configuration Release --runtime win-x64 --self-contained false --output ./publish
```

Copy the generated `publish/` folder to the server (SFTP, robocopy, etc.).

### 5. Configure TLS / HTTPS

Manual (GUI):
- Use the Certificates MMC to request/import a certificate into `LocalMachine\My`.

PowerShell:
```powershell
# Enterprise CA request
$cert = Get-Certificate -Template "WebServer" -SubjectName "CN=$env:COMPUTERNAME" -CertStoreLocation "Cert:\LocalMachine\My"

# Or import a PFX
Import-PfxCertificate -FilePath "C:\Temp\osmweb.pfx" -CertStoreLocation "Cert:\LocalMachine\My" -Password (Read-Host -AsSecureString "PFX password")
```

Register with HTTP.sys (PowerShell):
```powershell
$thumb = 'PASTE_THUMBPRINT'
$httpsPort = 8443
$svcAcct = 'YOURDOMAIN\svc-osmweb'
netsh http add urlacl "url=https://+:$httpsPort/" user=$svcAcct
foreach ($ip in @('0.0.0.0','[::]')) { netsh http add sslcert ipport=${ip}:$httpsPort certhash=$thumb appid="{$( [guid]::NewGuid() )}" }
```

### 6. Deploy files and set ACLs

PowerShell (server):
```powershell
New-Item -ItemType Directory -Path "C:\Services\OsmUserWeb" -Force
New-Item -ItemType Directory -Path "C:\Services\OsmUserWeb\logs" -Force
Copy-Item -Path "\path\to\publish\*" -Destination "C:\Services\OsmUserWeb" -Recurse -Force

# Apply tight ACLs: SYSTEM and Administrators FullControl, svc-osmweb ReadAndExecute; svc-osmweb Modify on logs only
```

### 7. Install and configure the Windows Service

PowerShell:
```powershell
$binPath = 'C:\Services\OsmUserWeb\OsmUserWeb.exe'
$svcAcct = 'YOURDOMAIN\svc-osmweb'
$svcPass = Read-Host -AsSecureString 'Service account password'
$passPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($svcPass))
sc.exe create OsmUserWeb binPath= $binPath obj= $svcAcct password= $passPlain start= auto DisplayName= "OSM User Web"

# Add environment variables (registry multi-string) for ASPNETCORE_URLS and default password if needed
```

### 8. Restrict network access

GUI: Create Windows Defender Firewall rules via Windows Firewall with Advanced Security.

PowerShell example:
```powershell
New-NetFirewallRule -DisplayName 'OsmUserWeb — allow HTTPS from admin subnet' -Direction Inbound -Protocol TCP -LocalPort 8443 -RemoteAddress '10.0.1.0/24' -Action Allow
New-NetFirewallRule -DisplayName 'OsmUserWeb — block HTTPS from all others' -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Block
```

### 9. Verify

PowerShell quick checks:
```powershell
sc.exe query OsmUserWeb
netsh http show sslcert ipport=0.0.0.0:8443
Get-EventLog -LogName Application -Source OsmUserWeb -Newest 20
```

## Scripts included in this repository

- `Install-OsmUserWeb.ps1` — Primary automated installer. Performs publish-copy (if provided), ACLs, HTTP.sys registration, service creation, environment variables, and firewall rules. Run from an elevated PowerShell session on the target server.
- `Install-OsmUserWeb-Remote.ps1` — Orchestrates remote installs from an admin workstation via PS Remoting (WinRM). Handles AD account creation locally; all other steps run on the target server.
- `Uninstall-OsmUserWeb.ps1` — Removes the service, HTTP.sys URL/SSL bindings, firewall rules, and application files. Accepts flags to remove the service account and certificate. Run locally on the target server.
- `Uninstall-OsmUserWeb-Remote.ps1` — Orchestrates remote uninstalls from an admin workstation via PS Remoting. AD account removal runs locally via RSAT; all other steps run on the target server.
- `Migrate-ToHttpSys.ps1` — Helper to migrate existing deployments to HTTP.sys binding model.
- `Start-OsmUserWeb.ps1` / `Stop-OsmUserWeb.ps1` — Convenience start/stop and health-check helpers.
- `src/PwshScript/Create-Proxmox-AC-SVR1.ps1` — Optional: creates a Proxmox VM to host the application (does not install the OS in-guest).

Refer to each script header for usage examples and parameters. Scripts are the recommended approach for repeatable and auditable deployments.

## Uninstall process

Manual uninstall (GUI + commands):

1. Stop the service: `sc.exe stop OsmUserWeb`.
2. Delete the Windows Service: `sc.exe delete OsmUserWeb`.
3. Remove HTTP.sys URL ACLs: `netsh http delete urlacl url=https://+:8443/` and delete SSL bindings for `0.0.0.0:8443` and `[::]:8443` using `netsh http delete sslcert ipport=...`.
4. Remove firewall rules created for the service.
5. Optionally remove `C:\Services\OsmUserWeb` (after backing up any configs you need).
6. If you created a service account and want it removed, do so via AD tools (GUI or `Remove-ADUser svc-osmweb`).

Automated uninstall — local (recommended for direct server access):

Run from an elevated PowerShell prompt on the target server:
```powershell
.\Uninstall-OsmUserWeb.ps1

# To also remove the service account and certificate
.\Uninstall-OsmUserWeb.ps1 -RemoveServiceAccount -RemoveCertificate
```

Automated uninstall — remote (from an admin workstation via PS Remoting):

```powershell
# Minimal — prompts for confirmation, connects as current user
.\Uninstall-OsmUserWeb-Remote.ps1 -TargetServer AC-WINADMIN

# Remove everything including the service account and certificate
.\Uninstall-OsmUserWeb-Remote.ps1 -TargetServer AC-WINADMIN -RemoveServiceAccount -RemoveCertificate

# With explicit credentials
.\Uninstall-OsmUserWeb-Remote.ps1 `
    -TargetServer         AC-WINADMIN `
    -Credential           (Get-Credential "opbta\Administrator") `
    -RemoveServiceAccount `
    -RemoveCertificate
```

The AD account removal (`-RemoveServiceAccount`) is always handled locally on the admin workstation via RSAT; all other steps run on the target server over WinRM.

The scripts attempt to safely roll back the items created during install: service, HTTP.sys bindings, firewall rules, and files. Review the scripts and run in a test environment before using on production.

---

If you want, I can:
- Run a quick validation that the install/uninstall scripts exist and display their parameter help blocks, or
- Update the `README.md` to link to this reorganised `INSTALL.md`.
