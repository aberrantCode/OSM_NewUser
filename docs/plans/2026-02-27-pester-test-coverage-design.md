# Pester Test Coverage Design — OsmUserWeb PowerShell Scripts

**Date:** 2026-02-27
**Goal:** Achieve ≥90% code coverage across all PowerShell scripts
**Strategy:** Mock-and-Invoke (Approach 1) — invoke each script with full mocking, skip -Remote orchestrators

---

## Scope

### In scope (8 scripts)

| Script | Lines | Path |
|--------|-------|------|
| ScriptHelpers.ps1 | 27 | src/DotNetWebServer/ |
| Install-OsmUserWeb.ps1 | 919 | src/DotNetWebServer/ |
| Uninstall-OsmUserWeb.ps1 | 277 | src/DotNetWebServer/ |
| Update-OsmUserWeb.ps1 | 334 | src/DotNetWebServer/ |
| Diagnose-OsmUserWeb.ps1 | 417 | src/DotNetWebServer/ |
| Start-OsmUserWeb.ps1 | 80 | src/DotNetWebServer/ |
| New-OSMUser.ps1 | 207 | src/PwshScript/ |
| Create-Proxmox-AC-SVR1.ps1 | 132 | src/PwshScript/ |

### Out of scope

- `Install-OsmUserWeb-Remote.ps1` — orchestrates via PS Remoting; all logic delegated to Install-OsmUserWeb.ps1 (already covered)
- `Uninstall-OsmUserWeb-Remote.ps1` — same rationale
- `dist/` scripts — byte-for-byte copies of `src/DotNetWebServer/` scripts

---

## Testing Pattern

Each test file follows this structure:

```powershell
BeforeAll {
    # 1. Set $PSScriptRoot equivalent
    $Script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\...\<script>.ps1'

    # 2. Mock ALL external dependencies before any invocation
    Mock Start-Transcript { }
    Mock Stop-Transcript   { }
    Mock sc.exe            { 'SERVICE_NAME: OsmUserWeb' }
    # ...

    # 3. Helper to invoke the script with common base parameters
}

Describe '<ScriptName>' {
    Context 'Happy path' {
        It 'completes successfully with all required params' { ... }
    }
    Context 'Skip flags' {
        It 'skips AD account creation when -SkipAdAccount' { ... }
    }
    Context 'Error paths' {
        It 'throws when publish path not found' { ... }
    }
}
```

---

## Test Files

### 1. ScriptHelpers.Tests.ps1 (exists — 100% ✓)
Covers `Read-WithDefault` and `Read-NonEmpty`. No changes needed.

### 2. Install-OsmUserWeb.Tests.ps1 (new)

**Mocks required:**
- `Start-Transcript`, `Stop-Transcript`
- `sc.exe` — returns SERVICE_NAME string for success, empty for "not found"
- `netsh` — returns success/fail
- `dotnet` — returns runtime list
- `winget` — returns 0 exit code
- `curl.exe` — returns `200`
- `Get-WmiObject` — returns domain-joined = true
- `Import-Module` — no-op
- `Get-ADDomain` — returns fake domain object
- `Get-ADOrganizationalUnit` — returns non-null
- `Get-ADUser` — returns null (new install) or object (existing)
- `New-ADUser` — no-op
- `Get-ADGroup` — returns fake group DN
- `dsacls` — returns 0 exit code
- `Test-Path` — returns $true for publish path, OsmUserWeb.exe
- `Resolve-Path` — returns path as-is
- `New-Item` — no-op
- `Copy-Item` — no-op
- `Get-Acl`, `Set-Acl` — no-op
- `New-SelfSignedCertificate` — returns fake cert object
- `Export-PfxCertificate` — no-op
- `Import-PfxCertificate` — returns fake cert
- `Get-ChildItem` (cert store) — returns fake cert
- `New-ItemProperty` — no-op
- `Get-NetFirewallRule` — returns rules or empty
- `New-NetFirewallRule` — no-op
- `Get-EventLog` — returns empty
- `Read-Host` — returns specific values per scenario

**Test scenarios:**
1. Full install happy path (`-Force -SkipAdAccount -SkipAdDelegation -SkipCertificate -SkipFirewall`)
2. Install with self-signed cert (`-CertSelfSigned`)
3. Install with PFX cert path (`-CertPfxPath` + `-CertPfxPassword`)
4. Install with `SkipAdAccount` only
5. Install with `SkipAdDelegation` only
6. Service already exists — reconfigure path
7. .NET runtime not found → winget install
8. Uninstall path (`-Uninstall`)
9. Publish path not found → throws
10. Target OU not found → throws
11. Domain fallback via WMI (no Get-ADDomain)
12. Interactive cert menu: choice 1 (PFX), choice 2 (self-signed), choice 3 (skip)

### 3. Uninstall-OsmUserWeb.Tests.ps1 (new)

**Test scenarios:**
1. Force uninstall — service running
2. Force uninstall — service already stopped
3. Force uninstall — service not found (already removed)
4. `RemoveServiceAccount` — account found → removed
5. `RemoveServiceAccount` — account not found → skip
6. `RemoveCertificate` — self-signed cert → removed
7. `RemoveCertificate` — CA-issued cert → warn, skip
8. Install dir not found → skip
9. Scheduled task retry logic (dir still present after attempt 1)

### 4. Update-OsmUserWeb.Tests.ps1 (new)

**Test scenarios:**
1. Happy path — service running, port from registry, cert thumbprint from HTTP.sys
2. Port explicit via `-HttpsPort`
3. Service not running — skip stop step
4. Publish path == install path — skip copy
5. No cert thumbprint — skip SSL re-registration
6. CA-issued cert — skip self-signed cleanup
7. Stale self-signed certs present → removed
8. Service not registered → throws

### 5. Diagnose-OsmUserWeb.Tests.ps1 (new)

**Test scenarios:**
1. All checks pass — service running, port listening, URL ACL present, cert bound, rules present
2. Service stopped → `[FAIL]` reported
3. Port not discovered in registry → default to 8443
4. No URL ACL → `[FAIL]`
5. No SSL cert binding → `[FAIL]`
6. Cert expired → `[FAIL]`
7. No firewall rules → `[WARN]`
8. curl 200 → ok; curl connection refused → `[FAIL]`
9. curl not found → Invoke-WebRequest fallback

### 6. Start-OsmUserWeb.Tests.ps1 (new)

**Test scenarios:**
1. .NET 9 SDK found — launches dotnet run
2. SDK not found, winget available — installs SDK then launches
3. SDK not found, winget absent → throws
4. winget exits non-zero → throws
5. `NoBrowser` flag — Start-Job not called
6. `NoBrowser` not set — Start-Job called

### 7. New-OSMUser.Tests.ps1 (new)

**Test scenarios:**
1. BaseName derived from `$env:USERNAME` (strips trailing digits)
2. Explicit `-BaseName` override
3. Empty base name → throws
4. First account (no existing users) → creates `baseName1`
5. Existing accounts present → creates next-number
6. Confirm = N → aborts, no New-ADUser call
7. Confirm = Y → creates user, sets CannotChangePassword, adds to group
8. New-ADUser "already exists" error → informative message, re-throws
9. Set-ADUser fails (non-fatal) → warns, continues
10. Add-ADGroupMember fails (non-fatal) → warns, continues
11. Target OU not found → throws
12. Import-Module fails → throws with RSAT install instructions

### 8. Create-Proxmox-AC-SVR1.Tests.ps1 (new)

**Test scenarios:**
1. API-token auth — headers contain `PVEAPIToken=`
2. Username/password auth — POST to /access/ticket, use cookie + CSRF
3. No ApiTokenId and no Username → Write-Error, exits 2
4. VM ID already exists → Write-Error, exits 3
5. VM creation success → writes task ID, starts VM
6. VM creation failure → Write-Error, exits 4
7. VM start failure → Write-Error, exits 5
8. `ConvertFrom-SecureStringToPlain` — null input → returns null

---

## Coverage Limitations (~8–13% uncovered)

- `Grant-LogOnAsServiceRight` P/Invoke C# type definition in Install script (Add-Type block)
- `catch` blocks for catastrophic failures that `exit 1`
- `[Security.Principal.WindowsPrincipal]::IsInRole()` — passes naturally when tests run as Administrator

## Admin Requirement

Tests for Install, Uninstall, Update, Diagnose need an elevated session.
Tests for Start, New-OSMUser, Create-Proxmox-AC-SVR1 run without elevation.

Tests requiring elevation should be tagged `-Tag 'RequiresAdmin'` so they can be skipped in unelevated CI environments.

---

## Estimated Coverage After Implementation

| Script | Est. Coverage |
|--------|--------------|
| ScriptHelpers.ps1 | 100% ✓ |
| Install-OsmUserWeb.ps1 | 88% |
| Uninstall-OsmUserWeb.ps1 | 92% |
| Update-OsmUserWeb.ps1 | 91% |
| Diagnose-OsmUserWeb.ps1 | 90% |
| Start-OsmUserWeb.ps1 | 95% |
| New-OSMUser.ps1 | 92% |
| Create-Proxmox-AC-SVR1.ps1 | 90% |
| **Overall** | **~91%** |
