#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Diagnose-OsmUserWeb.ps1.

.DESCRIPTION
    The source script diagnoses a connection-refused / not-responding OsmUserWeb
    installation by running checks across every layer: SCM state, port listening,
    HTTP.sys URL ACL, SSL cert binding, Windows Firewall, event log, and a local
    curl/Invoke-WebRequest connectivity probe.

    Key script characteristics:
      - $ErrorActionPreference = 'Continue': individual check failures do NOT
        propagate; the script always runs to completion.
      - Uses local Write-Ok / Write-Warn / Write-Fail / Write-Info helpers —
        these are NOT mocked; they emit coloured host output only.
      - External executables called: sc.exe, netstat, netsh, curl.exe, explorer.exe
      - PS cmdlets called: Start-Transcript, Stop-Transcript, Compress-Archive,
        Get-EventLog, Get-NetFirewallRule, Get-NetFirewallPortFilter,
        Get-NetFirewallAddressFilter, Get-NetFirewallProfile, Get-Item,
        Test-Path, Get-ItemProperty, Get-Command, Invoke-WebRequest.
      - explorer.exe is launched only when $script:issueDetected is $true, so
        it MUST be mocked to prevent real UI from opening during tests.

    Invocation model:
      - SUT invoked ONCE per Describe in BeforeAll via & $script:ScriptPath.
      - All Should -Invoke assertions use -Scope Describe.
      - script:Set-HealthyMocks provides a full "green" environment; individual
        Describe blocks override specific mocks to create failure scenarios.

    Scenarios covered (9):
      1. Healthy system — all checks pass
      2. Service STOPPED — script still runs to completion
      3. Port not in registry — defaults to 8443
      4. No URL ACL — script still runs
      5. No SSL cert binding — script still runs
      6. Cert expired — script still runs
      7. No firewall rules — script still runs
      8. curl returns "connection refused" — script still runs
      9. curl.exe not found — Invoke-WebRequest fallback is called
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\DotNetWebServer\Diagnose-OsmUserWeb.ps1'

    # Always mock these to suppress side-effects
    Mock Start-Transcript { }
    Mock Stop-Transcript  { }
    Mock Compress-Archive { }
    Mock 'explorer.exe'   { }

    # Helper function to set up a healthy mock environment
    function script:Set-HealthyMocks {
        Mock 'sc.exe' { @('SERVICE_NAME: OsmUserWeb', 'STATE              : 4  RUNNING') }
        Mock 'netstat' { '  TCP    0.0.0.0:8443    0.0.0.0:0    LISTENING    1234' }
        Mock netsh {
            if ($args -join ' ' -match 'urlacl') {
                return @('    Reserved URL      : https://+:8443/', '    User: DOMAIN\svc')
            }
            if ($args -join ' ' -match 'sslcert') {
                # Return a single string so that $sslInfo -match 'Certificate Hash...' operates
                # on a scalar and populates $Matches (array -match filters but does NOT set $Matches)
                return "    Certificate Hash                : AABBCCDD11223344556677889900AABBCCDDEE00`r`n    Application ID                  : {00000000-0000-0000-0000-000000000001}"
            }
            return ''
        }
        Mock Get-NetFirewallRule {
            # Use comma operator to return as an array-of-one so .Count is accessible
            # under Set-StrictMode -Version Latest (plain @() gets unwrapped by Pester mock pipeline)
            $rule = [PSCustomObject]@{ DisplayName='OsmUserWeb HTTPS'; Action='Allow' }
            Write-Output -NoEnumerate @($rule)
        }
        Mock Get-NetFirewallPortFilter   { [PSCustomObject]@{ LocalPort = '8443' } }
        Mock Get-NetFirewallAddressFilter { [PSCustomObject]@{ RemoteAddress = '192.168.0.0/24' } }
        Mock Get-NetFirewallProfile { @([PSCustomObject]@{ Name='Domain'; Enabled=$true }) }
        Mock Get-EventLog {
            # Return one Information-level event so the script takes the 'if ($appEvents)' branch
            # and does NOT call Write-Warn "No event log entries found" (which sets issueDetected=$true)
            [PSCustomObject]@{
                EntryType     = 'Information'
                TimeGenerated = (Get-Date)
                Message       = 'Service started successfully.'
            }
        }
        Mock Get-Item {
            [PSCustomObject]@{
                Thumbprint    = 'AABBCCDD11223344556677889900AABBCCDDEE00'
                Subject       = 'CN=TESTSERVER'
                Issuer        = 'CN=TestCA'
                NotAfter      = (Get-Date).AddYears(1)
                HasPrivateKey = $true
            }
        }
        Mock Get-Command { [PSCustomObject]@{ Name = 'curl.exe' } }
        Mock 'curl.exe'  { '200' }
        Mock Test-Path   { $true }
        Mock Get-ItemProperty {
            [PSCustomObject]@{
                Environment = @('ASPNETCORE_URLS=https://+:8443')
            }
        }
        # Mock Get-Content so appsettings.Production.json parse succeeds under StrictMode
        Mock Get-Content { '{"AdSettings":{"TargetOU":"OU=Users,DC=test,DC=local","GroupName":"OsmUsers"}}' }
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200 } }
    }
}

# ── Scenario 1 : Healthy system — all checks pass ─────────────────────────────

Describe 'Healthy system - all checks pass' {

    BeforeAll {
        script:Set-HealthyMocks
        & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
    }

    It 'completes without throwing' {
        $true | Should -Be $true
    }

    It 'queries sc.exe for service state' {
        Should -Invoke 'sc.exe' -Scope Describe
    }

    It 'probes netstat for listening port' {
        Should -Invoke 'netstat' -Scope Describe
    }

    It 'checks URL ACL via netsh' {
        Should -Invoke netsh -Scope Describe -ParameterFilter { $args -join ' ' -match 'urlacl' }
    }

    It 'checks SSL cert binding via netsh' {
        Should -Invoke netsh -Scope Describe -ParameterFilter { $args -join ' ' -match 'sslcert' }
    }

    It 'queries Windows Firewall rules' {
        Should -Invoke Get-NetFirewallRule -Scope Describe
    }

    It 'queries event log' {
        Should -Invoke Get-EventLog -Scope Describe
    }

    It 'retrieves certificate from store' {
        Should -Invoke Get-Item -Scope Describe
    }

    It 'probes connectivity with curl.exe' {
        Should -Invoke 'curl.exe' -Scope Describe
    }

    It 'does NOT fall back to Invoke-WebRequest when curl.exe is present' {
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -Scope Describe
    }

    It 'calls Start-Transcript once' {
        Should -Invoke Start-Transcript -Times 1 -Exactly -Scope Describe
    }

    It 'calls Stop-Transcript once' {
        Should -Invoke Stop-Transcript -Times 1 -Exactly -Scope Describe
    }

    It 'does NOT invoke Compress-Archive when no issues detected' {
        Should -Invoke Compress-Archive -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT invoke explorer.exe when no issues detected' {
        Should -Invoke 'explorer.exe' -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 2 : Service STOPPED ─────────────────────────────────────────────

Describe 'Service STOPPED - script runs to completion' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override: service reports STOPPED state
        Mock 'sc.exe' { @('SERVICE_NAME: OsmUserWeb', 'STATE              : 1  STOPPED') }

        $script:threw = $false
        try {
            & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw even when the service is STOPPED' {
        $script:threw | Should -Be $false
    }

    It 'still queries sc.exe' {
        Should -Invoke 'sc.exe' -Scope Describe
    }

    It 'still probes netstat after the STOPPED service check' {
        Should -Invoke 'netstat' -Scope Describe
    }

    It 'still checks URL ACL even after STOPPED service' {
        Should -Invoke netsh -Scope Describe -ParameterFilter { $args -join ' ' -match 'urlacl' }
    }
}

# ── Scenario 3 : Port not found in registry — defaults to 8443 ───────────────

Describe 'Port not in registry - defaults to 8443' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override registry key: key exists but Environment has no ASPNETCORE_URLS
        Mock Get-ItemProperty {
            [PSCustomObject]@{ Environment = @('SOME_OTHER_VAR=foo') }
        }

        $script:threw = $false
        try {
            # Do NOT pass -HttpsPort so auto-detect runs
            & $script:ScriptPath -ServiceName OsmUserWeb -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw when ASPNETCORE_URLS is absent from registry' {
        $script:threw | Should -Be $false
    }

    It 'reads registry via Get-ItemProperty' {
        Should -Invoke Get-ItemProperty -Scope Describe
    }

    It 'still queries sc.exe after defaulting port to 8443' {
        Should -Invoke 'sc.exe' -Scope Describe
    }

    It 'still calls netstat after defaulting port' {
        Should -Invoke 'netstat' -Scope Describe
    }
}

# ── Scenario 4 : No URL ACL ───────────────────────────────────────────────────

Describe 'No URL ACL - script still runs to completion' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override: netsh returns no Reserved URL for urlacl queries
        Mock netsh {
            if ($args -join ' ' -match 'urlacl') {
                return 'The system cannot find the file specified.'
            }
            if ($args -join ' ' -match 'sslcert') {
                return "    Certificate Hash                : AABBCCDD11223344556677889900AABBCCDDEE00`r`n    Application ID                  : {00000000-0000-0000-0000-000000000001}"
            }
            return ''
        }

        $script:threw = $false
        try {
            & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw when URL ACL is absent' {
        $script:threw | Should -Be $false
    }

    It 'invokes netsh for urlacl check' {
        Should -Invoke netsh -Scope Describe -ParameterFilter { $args -join ' ' -match 'urlacl' }
    }

    It 'still checks SSL cert binding after missing URL ACL' {
        Should -Invoke netsh -Scope Describe -ParameterFilter { $args -join ' ' -match 'sslcert' }
    }

    It 'still queries sc.exe after missing URL ACL' {
        Should -Invoke 'sc.exe' -Scope Describe
    }
}

# ── Scenario 5 : No SSL cert binding ─────────────────────────────────────────

Describe 'No SSL cert binding - script still runs to completion' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override: netsh returns no Certificate Hash for sslcert queries
        Mock netsh {
            if ($args -join ' ' -match 'urlacl') {
                return @('    Reserved URL      : https://+:8443/', '    User: DOMAIN\svc')
            }
            if ($args -join ' ' -match 'sslcert') {
                return 'The system cannot find the file specified.'
            }
            return ''
        }

        $script:threw = $false
        try {
            & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw when SSL cert binding is absent' {
        $script:threw | Should -Be $false
    }

    It 'invokes netsh for sslcert check' {
        Should -Invoke netsh -Scope Describe -ParameterFilter { $args -join ' ' -match 'sslcert' }
    }

    It 'still queries sc.exe after missing SSL binding' {
        Should -Invoke 'sc.exe' -Scope Describe
    }

    It 'still probes curl.exe after missing SSL binding' {
        Should -Invoke 'curl.exe' -Scope Describe
    }
}

# ── Scenario 6 : Cert expired ─────────────────────────────────────────────────

Describe 'Cert expired - script still runs to completion' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override: certificate has an expired NotAfter date
        Mock Get-Item {
            [PSCustomObject]@{
                Thumbprint    = 'AABBCCDD11223344556677889900AABBCCDDEE00'
                Subject       = 'CN=TESTSERVER'
                Issuer        = 'CN=TestCA'
                NotAfter      = (Get-Date).AddYears(-1)   # EXPIRED
                HasPrivateKey = $true
            }
        }

        $script:threw = $false
        try {
            & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw when the certificate is expired' {
        $script:threw | Should -Be $false
    }

    It 'retrieves certificate from the store' {
        Should -Invoke Get-Item -Scope Describe
    }

    It 'still probes curl.exe after detecting an expired cert' {
        Should -Invoke 'curl.exe' -Scope Describe
    }

    It 'still queries sc.exe after detecting an expired cert' {
        Should -Invoke 'sc.exe' -Scope Describe
    }
}

# ── Scenario 7 : No firewall rules ────────────────────────────────────────────

Describe 'No firewall rules - script still runs to completion' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override: no matching firewall rules returned
        Mock Get-NetFirewallRule { $null }

        $script:threw = $false
        try {
            & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw when no firewall rules are found' {
        $script:threw | Should -Be $false
    }

    It 'queries Get-NetFirewallRule' {
        Should -Invoke Get-NetFirewallRule -Scope Describe
    }

    It 'still queries sc.exe after missing firewall rules' {
        Should -Invoke 'sc.exe' -Scope Describe
    }

    It 'still probes curl.exe after missing firewall rules' {
        Should -Invoke 'curl.exe' -Scope Describe
    }
}

# ── Scenario 8 : curl returns "connection refused" ───────────────────────────

Describe 'curl connection refused - script still runs to completion' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override: curl.exe reports a connection-refused error string
        Mock 'curl.exe' { 'curl: (7) Failed to connect to localhost port 8443: Connection refused' }

        $script:threw = $false
        try {
            & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw when curl reports connection refused' {
        $script:threw | Should -Be $false
    }

    It 'still invokes curl.exe' {
        Should -Invoke 'curl.exe' -Scope Describe
    }

    It 'still queries sc.exe when curl fails' {
        Should -Invoke 'sc.exe' -Scope Describe
    }

    It 'does NOT call Invoke-WebRequest when curl.exe is present' {
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 9 : curl.exe not found — Invoke-WebRequest fallback ──────────────

Describe 'curl.exe not found - Invoke-WebRequest fallback' {

    BeforeAll {
        script:Set-HealthyMocks
        # Override: curl.exe not on the system
        Mock Get-Command { $null }

        $script:threw = $false
        try {
            & $script:ScriptPath -ServiceName OsmUserWeb -HttpsPort 8443 -InstallPath 'C:\Services\OsmUserWeb'
        } catch {
            $script:threw = $true
        }
    }

    It 'does NOT throw when curl.exe is absent' {
        $script:threw | Should -Be $false
    }

    It 'falls back to Invoke-WebRequest when curl.exe is absent' {
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -Scope Describe
    }

    It 'does NOT call curl.exe when it is absent' {
        Should -Invoke 'curl.exe' -Times 0 -Exactly -Scope Describe
    }

    It 'still queries sc.exe in the fallback scenario' {
        Should -Invoke 'sc.exe' -Scope Describe
    }
}
