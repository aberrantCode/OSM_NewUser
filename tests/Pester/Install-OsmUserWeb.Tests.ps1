#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Install-OsmUserWeb.ps1.

.DESCRIPTION
    The source script performs a full production install of OsmUserWeb:
      0.  Prerequisite checks (admin, domain-joined, RSAT).
      1.  Collect configuration inputs.
      2.  Install .NET 9 ASP.NET Core Hosting Bundle if absent.
      3.  Create the dedicated service account (svc-osmweb) in Active Directory.
      4.  Grant "Log on as a service" right on this server.
      5.  Delegate the minimum AD permissions to the target OU and group.
      6.  Deploy and harden application files and directory ACLs.
      7.  Write appsettings.Production.json.
      8.  Register certificate with HTTP.sys (TLS).
      9.  Register and configure the Windows Service.
     10.  Inject secrets into the service registry environment.
     11.  Configure Windows Service failure recovery.
     12.  Create Windows Firewall rules.
     13.  Start the service and verify it reaches the RUNNING state.

    Invocation model:
      - Tests MUST run as Administrator (the script throws otherwise).
        No mock is used for the admin check — tests are run elevated.
      - SUT invoked ONCE per Describe in BeforeAll via & $script:ScriptPath.
      - All Should -Invoke assertions use -Scope Describe.
      - script:Set-InstallMocks provides a full "happy path" mock environment.
        Individual Describe blocks override specific mocks for each scenario.
      - sc.exe mock uses a $global: counter (mock scriptblocks execute in
        Pester's module scope, so $script: counters inside mock bodies are
        inaccessible from the test-file scope).
      - Real publish directory and OsmUserWeb.exe are created in TestDrive so
        that Resolve-Path works without mocking.
      - Add-Type is mocked to prevent CSharp compilation errors when the type
        has already been defined in a prior test-session run.
      - Set-HardenedAcl is defined as a stub function in this file's scope so
        Pester wraps the stub rather than the SUT-internal definition.  This
        prevents AddAccessRule from trying to resolve OPBTA\svc-osmweb against
        the local Windows identity database.
      - ConvertTo-SecureString is mocked to avoid Microsoft.PowerShell.Security
        module-load failures that occur under Pester's module isolation.

    Scenarios covered (15):
      1.  Full install - all skip flags set (core path: dir, copy, acl, svc, reg)
      2.  SkipAdAccount - New-ADUser NOT called
      3.  AD account creation - New-ADUser IS called
      4.  AD account already exists - no duplicate create
      5.  AD delegation - dsacls called when not skipped
      6.  Target OU not found in AD - install aborted before file copy
      7.  .NET runtime absent - winget installs it
      8.  Service already registered - sc.exe config instead of create
      9.  Firewall rules created when not skipped
     10.  PFX cert path - Import-PfxCertificate called and netsh urlacl registered
     11.  CertSelfSigned - New-SelfSignedCertificate called and netsh urlacl called
     12.  OsmUserWeb.exe not in publish dir - script exits with code 1
     13.  Domain WMI fallback when Get-ADDomain fails
     14.  Uninstall path - sc.exe stop/delete and netsh called
     15.  Uninstall aborted - sc.exe stop NOT called
#>

BeforeAll {
    $script:ScriptPath  = Join-Path $PSScriptRoot '..\..\src\DotNet-DomainWebServer\Install-OsmUserWeb.ps1'
    $script:InstallPath = 'C:\FakeInstall\OsmUserWeb'
    $script:TargetOU    = 'OU=AdminAccounts,DC=opbta,DC=local'

    # Create a real publish directory in TestDrive so Resolve-Path works.
    # Use the module-qualified call so that later mocks on New-Item do not
    # intercept the test-setup creation.
    $script:PublishPath = "$TestDrive\publish"
    Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $script:PublishPath -Force | Out-Null
    Microsoft.PowerShell.Management\New-Item -ItemType File      -Path "$script:PublishPath\OsmUserWeb.exe" -Force | Out-Null

    # Empty publish dir used by Scenario 10 (no exe present).
    $script:EmptyPublishPath = "$TestDrive\empty_publish"
    Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $script:EmptyPublishPath -Force | Out-Null

    # Base params to run fully non-interactively.
    $script:BaseParams = @{
        PublishPath        = $script:PublishPath
        InstallPath        = $script:InstallPath
        TargetOU           = $script:TargetOU
        DefaultPassword    = 'D3faultP@ss!'
        SvcAccountPassword = 'SvcP@ss!'
        Force              = $true
        SkipAdAccount      = $true
        SkipAdDelegation   = $true
        SkipCertificate    = $true
        SkipFirewall       = $true
    }

    # ------------------------------------------------------------------
    # Permissive function stubs registered BEFORE Pester creates Mock
    # wrappers.  Several cmdlets have multi-parameter-set signatures
    # that reject piped PSCustomObjects on PS 7; defining a local
    # function first causes Pester to wrap this simpler signature.
    # ------------------------------------------------------------------

    function Remove-NetFirewallRule {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)]
            $InputObject,
            [string]$Name,
            [string]$DisplayName,
            $ErrorAction
        )
        process { }
    }

    function New-NetFirewallRule {
        [CmdletBinding()]
        param(
            [string]$DisplayName,
            [string]$Direction,
            [string]$Protocol,
            $LocalPort,
            [string]$RemoteAddress,
            [string]$Action
        )
    }

    function Get-NetFirewallRule {
        [CmdletBinding()]
        param(
            [string]$DisplayName,
            $ErrorAction
        )
    }

    function New-SelfSignedCertificate {
        [CmdletBinding()]
        param(
            $DnsName,
            $CertStoreLocation,
            $NotAfter,
            $KeyAlgorithm,
            $KeyLength,
            $KeyExportPolicy
        )
    }

    function Export-PfxCertificate {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)]
            $InputObject,
            [string]$FilePath,
            $Password,
            $CryptoAlgorithmOption
        )
        process { }
    }

    function Import-PfxCertificate {
        [CmdletBinding()]
        param(
            [string]$FilePath,
            [string]$CertStoreLocation,
            $Password
        )
    }

    function New-ItemProperty {
        [CmdletBinding()]
        param(
            [string]$Path,
            [string]$Name,
            [string]$PropertyType,
            [switch]$Force,
            $Value
        )
    }

    function Set-Content {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)]
            $Value,
            [string]$Path,
            [string]$Encoding,
            [switch]$Force
        )
        process { }
    }

    function New-Item {
        [CmdletBinding()]
        param(
            [string]$ItemType,
            [string]$Path,
            [switch]$Force
        )
    }

    function Copy-Item {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0, ValueFromPipeline)]
            $Path,
            [string]$Destination,
            [switch]$Recurse,
            [switch]$Force
        )
        process { }
    }

    function Set-Acl {
        [CmdletBinding()]
        param(
            [string]$Path,
            $AclObject
        )
    }

    function Get-Acl {
        [CmdletBinding()]
        param(
            [string]$Path,
            $ErrorAction
        )
    }

    function Remove-Item {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0, ValueFromPipeline)]
            $Path,
            [switch]$Recurse,
            [switch]$Force,
            $ErrorAction
        )
        process { }
    }

    # ConvertTo-SecureString lives in Microsoft.PowerShell.Security which may not
    # be loaded in the Pester module isolation context.  Defining a stub here
    # causes Pester to wrap this simpler signature rather than fail with
    # CommandNotFoundException when Mock tries to locate the real cmdlet.
    function ConvertTo-SecureString {
        [CmdletBinding()]
        param(
            [string]$String,
            [switch]$AsPlainText,
            [switch]$Force,
            [System.Security.SecureString]$SecureKey,
            [string]$Key
        )
        return New-Object System.Security.SecureString
    }

    # Set-HardenedAcl is an internal function defined in the SUT that calls
    # Get-Acl followed by AddAccessRule (which tries to resolve OPBTA\svc-osmweb).
    # Defining it here as a stub causes the SUT's dot-sourced scope to inherit
    # this definition via Pester's scoping model, preventing the identity-resolution
    # exception without having to mock individual ACL operations.
    function Set-HardenedAcl {
        [CmdletBinding()]
        param(
            [string]$Path,
            [string]$Account,
            [string]$AccountRights,
            [string]$Inherit
        )
        # Stub: no-op in tests.
    }

    # Grant-LogOnAsServiceRight is an internal SUT function that calls Add-Type
    # (mocked) and then invokes [OsmInstall.LsaUtil]::GrantSeServiceLogonRight.
    # Because Add-Type is mocked the type never exists; stub this function here
    # so it is interceptable before the type lookup is attempted.
    function Grant-LogOnAsServiceRight {
        [CmdletBinding()]
        param([string]$AccountName)
        # Stub: no-op in tests.
    }

    # ------------------------------------------------------------------
    # Set-InstallMocks — full happy-path mock environment.
    # Individual Describe blocks override specific mocks as needed.
    # ------------------------------------------------------------------
    function script:Set-InstallMocks {

        Mock Start-Transcript { }
        Mock Stop-Transcript  { }
        Mock Start-Sleep      { }
        Mock Add-Type         { }   # prevent CSharp compilation across test runs
        Mock ConvertTo-SecureString { New-Object System.Security.SecureString }

        # Domain / AD mocks
        Mock Get-WmiObject {
            [PSCustomObject]@{ PartOfDomain = $true; Domain = 'opbta.local' }
        }
        Mock Import-Module { }
        Mock Get-ADDomain  { [PSCustomObject]@{ DNSRoot = 'opbta.local'; NetBIOSName = 'OPBTA' } }
        Mock Get-ADOrganizationalUnit {
            [PSCustomObject]@{ DistinguishedName = 'OU=AdminAccounts,DC=opbta,DC=local' }
        }
        Mock Get-ADUser  { $null }
        Mock New-ADUser  { }
        Mock Get-ADGroup {
            [PSCustomObject]@{ DistinguishedName = 'CN=Domain Admins,DC=opbta,DC=local' }
        }
        Mock dsacls { $global:LASTEXITCODE = 0; return '' }

        # .NET runtime check
        Mock dotnet      { '  Microsoft.AspNetCore.App 9.0.1 [C:\Program Files\dotnet]' }
        Mock Get-Command { [PSCustomObject]@{ Name = 'winget.exe' } }
        Mock winget      { $global:LASTEXITCODE = 0; return 'OK' }

        # File deployment
        Mock New-Item  { [PSCustomObject]@{ FullName = 'C:\FakeInstall\OsmUserWeb' } }
        Mock Copy-Item { }
        # Return a stub ACL object whose methods are no-ops so that
        # AddAccessRule and SetAccessRuleProtection do not attempt to resolve
        # OPBTA\svc-osmweb against the local Windows identity database.
        Mock Get-Acl   {
            $fakeAcl = [PSCustomObject]@{}
            $fakeAcl | Add-Member -MemberType ScriptMethod -Name SetAccessRuleProtection -Value { param($p1,$p2) } -Force
            $fakeAcl | Add-Member -MemberType ScriptMethod -Name AddAccessRule           -Value { param($rule) }   -Force
            $fakeAcl
        }
        Mock Set-Acl   { }
        Mock Set-HardenedAcl { }
        Mock Set-Content { }
        Mock ConvertTo-Json { '{}' }
        Mock Get-ChildItem {
            $p = if ($Path) { $Path } else { $args[0] }
            if ($p -match 'LocalMachine|Cert:') { return @() }
            return @([PSCustomObject]@{
                FullName = "$p\OsmUserWeb.exe"
                Name     = 'OsmUserWeb.exe'
            })
        }

        # Service registration — new service (not yet registered on first query).
        $global:osmInstallScQueryIdx = 0
        Mock 'sc.exe' {
            if ($args -join ' ' -match 'query') {
                $global:osmInstallScQueryIdx++
                if ($global:osmInstallScQueryIdx -eq 1) {
                    # Not registered initially — triggers sc.exe create branch.
                    return 'FAILED 1060'
                }
                # Post-start wait loop — return RUNNING so the do/while exits.
                return 'SERVICE_NAME: OsmUserWeb  STATE              : 4  RUNNING'
            }
            $global:LASTEXITCODE = 0; return ''
        }

        # Registry and cert
        Mock New-ItemProperty { }
        Mock Get-NetFirewallRule  { return @() }
        Mock New-NetFirewallRule  { }
        Mock Remove-NetFirewallRule { }
        Mock New-SelfSignedCertificate {
            [PSCustomObject]@{ Thumbprint = 'SELFSIGNED0001'; NotAfter = (Get-Date).AddYears(1) }
        }
        Mock Export-PfxCertificate { }
        Mock Import-PfxCertificate {
            [PSCustomObject]@{ Thumbprint = 'IMPORTED0001' }
        }
        Mock Get-Item { $null }

        # Other
        Mock netsh       { $global:LASTEXITCODE = 0; return '' }
        Mock 'curl.exe'  { return '200' }
        Mock Get-EventLog { return @() }
        Mock Read-Host   { return 'Y' }
        Mock Remove-Item { }
    }
}

# ── Scenario 1 : Full install — all skip flags set ────────────────────────────

Describe 'Full install - all skip flags set' {

    BeforeAll {
        script:Set-InstallMocks

        & $script:ScriptPath @script:BaseParams *>$null
    }

    It 'creates the install directory via New-Item' {
        Should -Invoke New-Item -Scope Describe
    }

    It 'copies application files via Copy-Item' {
        Should -Invoke Copy-Item -Scope Describe
    }

    It 'hardens directory ACLs via Set-HardenedAcl' {
        Should -Invoke Set-HardenedAcl -Scope Describe
    }

    It 'writes the production config via Set-Content' {
        Should -Invoke Set-Content -Scope Describe
    }

    It 'registers the Windows Service via sc.exe create' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'create'
        }
    }

    It 'injects secrets into the registry via New-ItemProperty' {
        Should -Invoke New-ItemProperty -Scope Describe
    }

    It 'starts the service via sc.exe start' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }
}

# ── Scenario 2 : SkipAdAccount — New-ADUser NOT called ───────────────────────

Describe 'SkipAdAccount - New-ADUser not called' {

    BeforeAll {
        script:Set-InstallMocks

        & $script:ScriptPath @script:BaseParams *>$null
    }

    It 'does NOT call New-ADUser when -SkipAdAccount is set' {
        Should -Invoke New-ADUser -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 3 : AD account creation — New-ADUser IS called ──────────────────

Describe 'AD account creation - New-ADUser called once' {

    BeforeAll {
        script:Set-InstallMocks

        $p = $script:BaseParams.Clone()
        $p['SkipAdAccount'] = $false

        & $script:ScriptPath @p *>$null
    }

    It 'calls New-ADUser exactly once to create the service account' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 4 : AD account already exists — no duplicate create ──────────────

Describe 'AD account already exists - New-ADUser not called' {

    BeforeAll {
        script:Set-InstallMocks

        # Override: account already exists.
        Mock Get-ADUser { [PSCustomObject]@{ SamAccountName = 'svc-osmweb' } }

        $p = $script:BaseParams.Clone()
        $p['SkipAdAccount'] = $false

        & $script:ScriptPath @p *>$null
    }

    It 'does NOT call New-ADUser when the account already exists' {
        Should -Invoke New-ADUser -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 5 : AD delegation — dsacls called when not skipped ──────────────

Describe 'AD delegation - dsacls called when SkipAdDelegation is false' {

    BeforeAll {
        script:Set-InstallMocks

        $p = $script:BaseParams.Clone()
        $p['SkipAdAccount']    = $false   # account creation enabled
        $p['SkipAdDelegation'] = $false   # delegation enabled

        & $script:ScriptPath @p *>$null
    }

    It 'calls dsacls at least once to delegate OU permissions' {
        Should -Invoke dsacls -Scope Describe
    }

    It 'calls New-ADUser to create the service account' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe
    }
}

# ── Target OU not found in AD — install aborted ──────────────────────────────

Describe 'Target OU not found in AD — install aborted' {
    BeforeAll {
        script:Set-InstallMocks
        Mock Get-ADOrganizationalUnit { throw 'OU not found' }

        $p = $script:BaseParams.Clone()
        $p['SkipAdAccount']    = $false   # triggers OU lookup (either skip=false is sufficient)
        $p['SkipAdDelegation'] = $false

        # The SUT catches the OU error internally and calls exit 1 — this does NOT
        # surface as a thrown exception when invoked with &; it simply terminates
        # the child scope (same behaviour as Scenario 10 / missing-exe test).
        & $script:ScriptPath @p *>$null
    }

    It 'does NOT call Copy-Item when the OU lookup fails' {
        Should -Invoke Copy-Item -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call sc.exe create when the OU lookup fails' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'create'
        }
    }
}

# ── Scenario 6 : .NET runtime absent — winget installs it ────────────────────

Describe '.NET runtime absent - winget installs it' {

    BeforeAll {
        script:Set-InstallMocks

        # Override: dotnet returns empty on the first call (no runtime present).
        $global:osmInstallDotnetIdx = 0
        Mock dotnet {
            $global:osmInstallDotnetIdx++
            if ($global:osmInstallDotnetIdx -eq 1) { return '' }
            return '  Microsoft.AspNetCore.App 9.0.1 [C:\Program Files\dotnet]'
        }

        & $script:ScriptPath @script:BaseParams *>$null
    }

    It 'calls winget exactly once to install the .NET runtime' {
        Should -Invoke winget -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 7 : Service already registered — sc.exe config instead of create ─

Describe 'Service already registered - sc.exe config used instead of create' {

    BeforeAll {
        script:Set-InstallMocks

        # Override: first query returns SERVICE_NAME present — triggers config branch.
        Mock 'sc.exe' {
            if ($args -join ' ' -match 'query') {
                # Always return registered+RUNNING so config path is taken.
                return 'SERVICE_NAME: OsmUserWeb  STATE              : 4  RUNNING'
            }
            $global:LASTEXITCODE = 0; return ''
        }

        & $script:ScriptPath @script:BaseParams *>$null
    }

    It 'calls sc.exe config to reconfigure the existing service' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'config'
        }
    }

    It 'does NOT call sc.exe create when service is already registered' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'create'
        }
    }
}

# ── Scenario 8 : Firewall rules created when not skipped ─────────────────────

Describe 'Firewall rules created when SkipFirewall is false' {

    BeforeAll {
        script:Set-InstallMocks

        $p = $script:BaseParams.Clone()
        $p['SkipFirewall'] = $false

        & $script:ScriptPath @p *>$null
    }

    It 'creates at least one firewall rule via New-NetFirewallRule' {
        Should -Invoke New-NetFirewallRule -Scope Describe
    }
}

# ── PFX cert path — Import-PfxCertificate called ────────────────────────────

Describe 'PFX cert path — Import-PfxCertificate called' {
    BeforeAll {
        script:Set-InstallMocks
        # Create a placeholder PFX file in TestDrive (doesn't need to be real PFX — Import-PfxCertificate is mocked)
        $pfxPath = "$TestDrive\test.pfx"
        Microsoft.PowerShell.Management\New-Item -ItemType File -Path $pfxPath -Force | Out-Null

        $p = $script:BaseParams.Clone()
        $p.Remove('SkipCertificate')
        $p['CertPfxPath']     = $pfxPath
        $p['CertPfxPassword'] = 'PfxP@ss!'

        $script:pfxThrew = $false
        try { & $script:ScriptPath @p *>$null }
        catch { $script:pfxThrew = $true }
    }

    It 'does not throw' { $script:pfxThrew | Should -Be $false }
    It 'calls Import-PfxCertificate to load the certificate' {
        Should -Invoke Import-PfxCertificate -Times 1 -Exactly -Scope Describe
    }
    It 'registers URL ACL via netsh' {
        Should -Invoke netsh -Scope Describe -ParameterFilter { $args -join ' ' -match 'urlacl' }
    }
}

# ── Scenario 9 : CertSelfSigned — New-SelfSignedCertificate called ───────────

Describe 'CertSelfSigned - self-signed cert created and HTTP.sys URL ACL registered' {

    BeforeAll {
        script:Set-InstallMocks

        # The self-signed path uses Get-ChildItem on Cert:\LocalMachine\My.
        # Return empty so a new cert is always generated (not reused).
        Mock Get-ChildItem {
            $p = if ($Path) { $Path } else { $args[0] }
            if ($p -match 'LocalMachine|Cert:') { return @() }
            return @([PSCustomObject]@{
                FullName = "$p\OsmUserWeb.exe"
                Name     = 'OsmUserWeb.exe'
            })
        }

        # Export-PfxCertificate is called with the cert object via pipeline.
        # The mock stub defined in BeforeAll is permissive; no override needed.
        Mock Export-PfxCertificate { }

        $p = $script:BaseParams.Clone()
        $p.Remove('SkipCertificate')
        $p['CertSelfSigned'] = $true

        & $script:ScriptPath @p *>$null
    }

    It 'calls New-SelfSignedCertificate exactly once' {
        Should -Invoke New-SelfSignedCertificate -Times 1 -Exactly -Scope Describe
    }

    It 'registers a URL ACL via netsh http add urlacl' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'urlacl'
        }
    }
}

# ── Scenario 10 : OsmUserWeb.exe not in publish dir — script exits ─────────────

Describe 'OsmUserWeb.exe not in publish dir - no deployment steps run' {

    BeforeAll {
        script:Set-InstallMocks

        # $script:EmptyPublishPath was created in BeforeAll using the module-
        # qualified call before any mocks existed, so the real dir is on disk.
        $p = $script:BaseParams.Clone()
        $p['PublishPath'] = $script:EmptyPublishPath

        # The SUT throws and calls exit 1 inside its own catch block; when
        # invoked with & that terminates the child scope without surfacing a
        # thrown exception in the Pester host.
        & $script:ScriptPath @p *>$null
    }

    It 'does NOT call sc.exe create when the exe is missing from publish dir' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'create'
        }
    }

    It 'does NOT call Copy-Item when the exe is missing from publish dir' {
        Should -Invoke Copy-Item -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 11 : Domain WMI fallback when Get-ADDomain fails ────────────────

Describe 'Domain WMI fallback when Get-ADDomain fails' {

    BeforeAll {
        script:Set-InstallMocks

        # Override: Get-ADDomain throws (DC not reachable — double-hop scenario).
        Mock Get-ADDomain { throw 'Cannot contact DC' }

        # Ensure WMI returns full domain info for the fallback path.
        Mock Get-WmiObject {
            [PSCustomObject]@{ PartOfDomain = $true; Domain = 'opbta.local' }
        }

        $script:threwOnFallback = $false
        try {
            & $script:ScriptPath @script:BaseParams *>$null
        } catch {
            $script:threwOnFallback = $true
        }
    }

    It 'does NOT throw when Get-ADDomain fails and WMI fallback is used' {
        $script:threwOnFallback | Should -Be $false
    }

    It 'falls back to Get-WmiObject for domain discovery' {
        Should -Invoke Get-WmiObject -Scope Describe
    }

    It 'still completes the install - sc.exe start is called' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }
}

# ── Scenario 12 : Uninstall path — sc.exe stop/delete and netsh called ───────

Describe 'Uninstall path - service stopped and bindings removed' {

    BeforeAll {
        script:Set-InstallMocks

        # Uninstall path uses Read-Host for confirmation.
        Mock Read-Host { 'Y' }
        Mock Remove-Item { }

        # sc.exe mock for uninstall: stop and delete calls succeed.
        Mock 'sc.exe' {
            $global:LASTEXITCODE = 0; return ''
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Uninstall *>$null
    }

    It 'calls sc.exe stop during uninstall' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'calls sc.exe delete during uninstall' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'delete'
        }
    }

    It 'calls netsh to remove URL ACL and sslcert bindings' {
        Should -Invoke netsh -Scope Describe
    }
}

# ── Scenario 13 : Uninstall aborted — sc.exe stop NOT called ─────────────────

Describe 'Uninstall aborted - no destructive actions taken' {

    BeforeAll {
        script:Set-InstallMocks

        # User enters 'N' at the uninstall confirmation prompt.
        Mock Read-Host { 'N' }

        $script:threwOnAbort = $false
        try {
            & $script:ScriptPath -InstallPath $script:InstallPath -Uninstall *>$null
        } catch {
            $script:threwOnAbort = $true
        }
    }

    It 'does NOT throw when the user aborts uninstall' {
        $script:threwOnAbort | Should -Be $false
    }

    It 'does NOT call sc.exe stop when uninstall is aborted' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'does NOT call sc.exe delete when uninstall is aborted' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'delete'
        }
    }
}
