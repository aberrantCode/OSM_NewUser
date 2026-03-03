#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Uninstall-OsmUserWeb.ps1.

.DESCRIPTION
    The source script:
      1. Validates the caller is running as Administrator (throws if not).
      2. Discovers the HTTPS port from the service registry key.
      3. Discovers the bound certificate thumbprint from HTTP.sys.
      4. Prompts for confirmation unless -Force is specified.
      5. Stops and deletes the Windows Service (sc.exe stop / delete).
      6. Removes HTTP.sys URL ACL and SSL cert bindings (netsh delete).
      7. Removes Windows Firewall rules (Remove-NetFirewallRule).
      8. Deletes application files via a scheduled task (runs as SYSTEM).
      9. Optionally removes the self-signed certificate from the store.
     10. Optionally removes the AD service account.

    Invocation model:
      - Tests MUST run as Administrator (the script throws otherwise).
        No mock is used for the admin check - tests are run elevated.
      - SUT invoked ONCE per Describe in BeforeAll via & $script:ScriptPath.
      - All Should -Invoke assertions use -Scope Describe.
      - script:Set-UninstallMocks provides a full "happy path" mock environment.
        Individual Describe blocks override specific mocks to create scenarios.
      - netsh mocks return a scalar string (NOT an array) so that the -match
        operator populates $Matches as the SUT expects.
      - sc.exe query mock returns 'STATE : 1  STOPPED' so the do/while loop
        in the SUT exits immediately without real sleeping.

    Scenarios covered (9):
      1. Force uninstall - service registered
      2. Force uninstall - service not registered
      3. Force uninstall - install directory absent
      4. No firewall rules to remove
      5. -RemoveServiceAccount: account found
      6. -RemoveServiceAccount: account not found
      7. -RemoveCertificate: self-signed cert
      8. -RemoveCertificate: CA-issued cert (not removed)
      9. User aborts at confirmation (no -Force)
#>

BeforeAll {
    $script:ScriptPath  = Join-Path $PSScriptRoot '..\..\src\DotNet-DomainWebServer\Uninstall-OsmUserWeb.ps1'
    $script:InstallPath = 'C:\FakeInstall\OsmUserWeb'

    # ------------------------------------------------------------------
    # Permissive function stubs registered BEFORE Pester creates Mock
    # wrappers.  On PS 7 (where the test runner lives) several cmdlets
    # are either absent (New-Guid) or have multi-parameter-set signatures
    # that reject piped PSCustomObjects (Remove-NetFirewallRule, Remove-ADUser).
    # Defining a local function first causes Pester to wrap this simpler
    # signature rather than the real cmdlet.
    # ------------------------------------------------------------------

    # New-Guid was removed in PS 7; the SUT calls it as a cmdlet.
    function New-Guid {
        return [System.Guid]::NewGuid()
    }

    # Remove-NetFirewallRule: piped PSCustomObject causes AmbiguousParameterSet
    # when Pester replicates the real cmdlet's many parameter sets.
    function Remove-NetFirewallRule {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline)]
            $InputObject,
            [string]$Name,
            [string]$DisplayName
        )
        process { }
    }

    # Remove-ADUser: the real cmdlet requires a typed Identity parameter.
    # A permissive stub lets Pester intercept the call without validation errors.
    function Remove-ADUser {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, ValueFromPipeline)]
            $Identity,
            [switch]$Confirm
        )
        process { }
    }

    # Register-ScheduledTask: -Action expects CimInstance[] but our mock
    # New-ScheduledTaskAction returns PSCustomObject.  A permissive stub avoids
    # argument transformation errors on PS 7.
    function Register-ScheduledTask {
        [CmdletBinding()]
        param(
            [string]$TaskName,
            $Action,
            $Settings,
            [string]$RunLevel,
            [string]$User,
            [switch]$Force
        )
    }

    # Companion stubs so Pester wraps simpler signatures for these as well.
    function New-ScheduledTaskAction {
        [CmdletBinding()]
        param($Execute, $Argument)
    }

    function New-ScheduledTaskSettingsSet {
        [CmdletBinding()]
        param($ExecutionTimeLimit)
    }

    function Start-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
    }

    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName, $ErrorAction)
    }

    function Unregister-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName, [switch]$Confirm, $ErrorAction)
    }

    function script:Set-UninstallMocks {
        Mock 'sc.exe' {
            if ($args -join ' ' -match 'query') {
                return 'SERVICE_NAME: OsmUserWeb   STATE              : 1  STOPPED'
            }
            $global:LASTEXITCODE = 0; return ''
        }
        Mock netsh {
            if ($args -join ' ' -match 'show sslcert') {
                return "    Certificate Hash    : AABB1122334455667788990011AABBCCDDEE0000`r`n    Application ID: {test}"
            }
            if ($args -join ' ' -match 'show urlacl') {
                return "    Reserved URL      : https://+:8443/"
            }
            $global:LASTEXITCODE = 0; return ''
        }
        Mock Get-NetFirewallRule {
            # Use Write-Output -NoEnumerate so Pester does not unwrap the single-element array.
            # Under Set-StrictMode -Version Latest, $fwRules.Count requires an array (not scalar).
            Write-Output -NoEnumerate @([PSCustomObject]@{ DisplayName = 'OsmUserWeb HTTPS' })
        }
        Mock Remove-NetFirewallRule { }
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [PSCustomObject]@{ Environment = @('ASPNETCORE_URLS=https://+:8443') } }
        Mock Get-Process { $null }
        Mock Register-ScheduledTask { [PSCustomObject]@{ TaskName = 'FakeTask' } }
        Mock New-ScheduledTaskAction { [PSCustomObject]@{} }
        Mock New-ScheduledTaskSettingsSet { [PSCustomObject]@{ ExecutionTimeLimit = 'PT2M' } }
        Mock Start-ScheduledTask { }
        Mock Get-ScheduledTask { [PSCustomObject]@{ State = 'Ready' } }
        Mock Unregister-ScheduledTask { }
        Mock Start-Sleep { }
        Mock Import-Module { }
        Mock Get-ADUser { $null }
        Mock Remove-ADUser { }
        Mock Get-Item { $null }
        Mock Remove-Item { }
        Mock Read-Host { 'Y' }
    }
}

# ── Scenario 1 : Force uninstall — service registered ────────────────────────

Describe 'Force uninstall - service registered' {

    BeforeAll {
        script:Set-UninstallMocks

        # Counter-based Test-Path to let the scheduled task loop succeed:
        # First call to InstallPath returns $true (dir exists), subsequent calls return $false (dir gone).
        $script:testPathCount = 0
        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            if ($args[0] -eq $script:InstallPath) {
                $script:testPathCount++
                return $script:testPathCount -eq 1
            }
            return $true
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Force *>$null
    }

    It 'stops the service via sc.exe stop' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'deletes the service via sc.exe delete' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'delete'
        }
    }

    It 'removes the URL ACL via netsh delete urlacl' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'delete urlacl'
        }
    }

    It 'removes the SSL cert binding via netsh delete sslcert' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'delete sslcert'
        }
    }

    It 'removes firewall rules via Remove-NetFirewallRule' {
        Should -Invoke Remove-NetFirewallRule -Scope Describe
    }

    It 'registers a scheduled task to delete application files' {
        Should -Invoke Register-ScheduledTask -Scope Describe
    }

    It 'starts the scheduled task' {
        Should -Invoke Start-ScheduledTask -Scope Describe
    }

    It 'unregisters the scheduled task after completion' {
        Should -Invoke Unregister-ScheduledTask -Scope Describe
    }
}

# ── Scenario 2 : Force uninstall — service not registered ────────────────────

Describe 'Force uninstall - service not registered' {

    BeforeAll {
        script:Set-UninstallMocks

        # sc.exe query returns output without SERVICE_NAME so svcExists is false
        Mock 'sc.exe' {
            if ($args -join ' ' -match 'query') {
                return 'The specified service does not exist as an installed service.'
            }
            $global:LASTEXITCODE = 0; return ''
        }

        # Install dir absent so scheduled task is not triggered
        $script:testPathCount2 = 0
        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            return $false
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Force *>$null
    }

    It 'does NOT call sc.exe stop when service is not registered' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'does NOT call sc.exe delete when service is not registered' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'delete'
        }
    }
}

# ── Scenario 3 : Force uninstall — install directory absent ──────────────────

Describe 'Force uninstall - install directory absent' {

    BeforeAll {
        script:Set-UninstallMocks

        # Use ParameterFilter mocks to override the catch-all Test-Path { $true }
        # registered inside Set-UninstallMocks.  ParameterFilter mocks have higher
        # priority than catch-all mocks, so they win even when registered after.
        # Note: $script: variables are NOT accessible in mock scriptblocks (they
        # resolve to Pester's own script scope), so use a literal path string.
        Mock Test-Path { $false } -ParameterFilter {
            $Path -eq 'C:\FakeInstall\OsmUserWeb' -or
            $LiteralPath -eq 'C:\FakeInstall\OsmUserWeb'
        }

        & $script:ScriptPath -InstallPath 'C:\FakeInstall\OsmUserWeb' -Force *>$null
    }

    It 'does NOT register a scheduled task when the install directory is absent' {
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 4 : No firewall rules to remove ─────────────────────────────────

Describe 'No firewall rules to remove' {

    BeforeAll {
        script:Set-UninstallMocks

        # Override: no matching firewall rules
        Mock Get-NetFirewallRule { $null }

        # Install dir absent to keep the scenario simple
        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            return $false
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Force *>$null
    }

    It 'does NOT call Remove-NetFirewallRule when no rules are found' {
        Should -Invoke Remove-NetFirewallRule -Times 0 -Exactly -Scope Describe
    }

    It 'still queries Get-NetFirewallRule' {
        Should -Invoke Get-NetFirewallRule -Scope Describe
    }
}

# ── Scenario 5 : -RemoveServiceAccount: account found ────────────────────────

Describe '-RemoveServiceAccount - AD account found' {

    BeforeAll {
        script:Set-UninstallMocks

        # Override: AD user exists
        Mock Get-ADUser { [PSCustomObject]@{ SamAccountName = 'svc-osmweb' } }

        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            return $false
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Force -RemoveServiceAccount *>$null
    }

    It 'calls Remove-ADUser exactly once when the account is found' {
        Should -Invoke Remove-ADUser -Times 1 -Exactly -Scope Describe
    }

    It 'imports the ActiveDirectory module' {
        Should -Invoke Import-Module -Scope Describe -ParameterFilter {
            $args[0] -eq 'ActiveDirectory' -or $Name -eq 'ActiveDirectory'
        }
    }
}

# ── Scenario 6 : -RemoveServiceAccount: account not found ────────────────────

Describe '-RemoveServiceAccount - AD account not found' {

    BeforeAll {
        script:Set-UninstallMocks

        # Get-ADUser already returns $null in Set-UninstallMocks (no override needed)
        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            return $false
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Force -RemoveServiceAccount *>$null
    }

    It 'does NOT call Remove-ADUser when the account does not exist' {
        Should -Invoke Remove-ADUser -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 7 : -RemoveCertificate: self-signed cert ────────────────────────

Describe '-RemoveCertificate - self-signed certificate is removed' {

    BeforeAll {
        script:Set-UninstallMocks

        # Override: certificate exists and is self-signed (Subject == Issuer == CN=<hostname>)
        $computerName = $env:COMPUTERNAME
        Mock Get-Item {
            [PSCustomObject]@{
                Thumbprint = 'AABB1122334455667788990011AABBCCDDEE0000'
                Subject    = "CN=$computerName"
                Issuer     = "CN=$computerName"
            }
        }

        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            if ($args[0] -eq $script:InstallPath) { return $false }
            return $true
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Force -RemoveCertificate *>$null
    }

    It 'calls Remove-Item targeting the Cert:\LocalMachine store' {
        Should -Invoke Remove-Item -Scope Describe -ParameterFilter {
            $Path -match 'Cert:\\LocalMachine'
        }
    }
}

# ── Scenario 8 : -RemoveCertificate: CA-issued cert (not removed) ────────────

Describe '-RemoveCertificate - CA-issued certificate is left in place' {

    BeforeAll {
        script:Set-UninstallMocks

        # Override: certificate exists but was issued by a real CA (Subject != Issuer)
        Mock Get-Item {
            [PSCustomObject]@{
                Thumbprint = 'AABB1122334455667788990011AABBCCDDEE0000'
                Subject    = 'CN=osmweb.example.com'
                Issuer     = 'CN=EnterpriseCA'
            }
        }

        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            if ($args[0] -eq $script:InstallPath) { return $false }
            return $true
        }

        & $script:ScriptPath -InstallPath $script:InstallPath -Force -RemoveCertificate *>$null
    }

    It 'does NOT call Remove-Item for the certificate store when cert is CA-issued' {
        Should -Invoke Remove-Item -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $Path -match 'Cert:\\LocalMachine'
        }
    }
}

# ── Scenario 9 : User aborts at confirmation (no -Force) ─────────────────────

Describe 'User aborts at confirmation prompt' {

    BeforeAll {
        script:Set-UninstallMocks

        # Override: user enters 'N' at the prompt
        Mock Read-Host { 'N' }

        Mock Test-Path {
            if ($args[0] -match 'HKLM') { return $true }
            return $false
        }

        # The script calls exit 0 in a child scope when invoked with &,
        # which terminates the child process without affecting the Pester host.
        # Capture any thrown exception for completeness.
        $script:threwOnAbort = $false
        try {
            & $script:ScriptPath -InstallPath $script:InstallPath *>$null
        } catch {
            $script:threwOnAbort = $true
        }
    }

    It 'does NOT throw when the user aborts' {
        $script:threwOnAbort | Should -Be $false
    }

    It 'does NOT call sc.exe stop after user aborts' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'does NOT register a scheduled task after user aborts' {
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly -Scope Describe
    }
}
