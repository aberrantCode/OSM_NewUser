#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Update-OsmUserWeb.ps1.

.DESCRIPTION
    The source script performs an in-place binary update of an installed OsmUserWeb
    Windows Service:
      1. Admin check — throws if not Administrator.
      2. Service registered check via sc.exe query.
      3. Resolve publish path; verify OsmUserWeb.exe exists; read version via
         [System.Diagnostics.FileVersionInfo]::GetVersionInfo().
      4. Read service account from Get-WmiObject Win32_Service.
      5. Read HTTPS port from registry (Get-ItemProperty) or supplied -HttpsPort.
      6. Get cert thumbprint from netsh http show sslcert.
      7. Show summary; if not -Force, call Read-Host; exit 0 on N.
      8. Stop service if RUNNING (sc.exe stop), wait for STOPPED.
      9. Copy binaries (excluding appsettings.Production.json) if paths differ.
     10. Self-signed cert duplicate cleanup if active cert is self-signed.
     11. Re-register HTTP.sys: netsh delete/add urlacl, delete/add sslcert.
     12. Start service (sc.exe start), wait for RUNNING; probe with curl.exe.

    Invocation model:
      - Tests MUST run as Administrator (the script throws otherwise).
        No mock is used for the admin check — tests are run elevated.
      - SUT invoked ONCE per Describe in BeforeAll via & $script:ScriptPath.
      - All Should -Invoke assertions use -Scope Describe.
      - script:Set-UpdateMocks provides a full "happy path" mock environment.
        Individual Describe blocks override specific mocks for each scenario.
      - netsh mock returns a scalar string (NOT an array) so that the -match
        operator populates $Matches as the SUT expects.
      - sc.exe mock uses a $global: counter (mock scriptblocks execute in Pester's
        module scope, so $script: counters inside mock bodies are inaccessible from
        the test-file scope and would throw StrictMode errors in the SUT).
      - Real publish directory and OsmUserWeb.exe are created in TestDrive so that
        Resolve-Path and [FileVersionInfo]::GetVersionInfo() work without mocking.
      - The SUT calls exit 1 inside its own catch block; when invoked with &, that
        exit terminates the child scope without surfacing as a thrown exception in
        the Pester host.  Scenarios relying on error paths therefore assert on
        call counts (what was NOT called) rather than on thrown exceptions.

    Scenarios covered (8):
      1. Happy path — service RUNNING, port from registry
      2. Explicit -HttpsPort supplied — registry NOT read
      3. Service already STOPPED — sc.exe stop NOT called
      4. Publish path == Install path — Copy-Item NOT called
      5. No HTTP.sys SSL cert binding — netsh add sslcert NOT called
      6. Self-signed cert — stale duplicates removed
      7. Service not registered — stop/copy/start NOT called
      8. User aborts at confirmation — stop/copy NOT called
#>

BeforeAll {
    $script:ScriptPath  = Join-Path $PSScriptRoot '..\..\src\DotNetWebServer\Update-OsmUserWeb.ps1'
    $script:InstallPath = 'C:\FakeInstall\OsmUserWeb'

    # Create a real publish directory in TestDrive so Resolve-Path and
    # [FileVersionInfo]::GetVersionInfo() work without needing mocks.
    $script:PublishPath = "$TestDrive\publish"
    New-Item -ItemType Directory -Path $script:PublishPath -Force | Out-Null
    New-Item -ItemType File      -Path "$script:PublishPath\OsmUserWeb.exe" -Force | Out-Null

    # ------------------------------------------------------------------
    # Permissive function stubs registered BEFORE Pester creates Mock
    # wrappers.  Copy-Item with piped PSCustomObjects and -Recurse can
    # trigger AmbiguousParameterSet errors on PS 7; a permissive stub avoids that.
    # ------------------------------------------------------------------
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

    # Get-Process: used by SUT to wait for the process to exit after stopping.
    function Get-Process {
        [CmdletBinding()]
        param(
            [string]$Name,
            $ErrorAction
        )
    }

    # ---------------------------------------------------------------
    # Set-UpdateMocks — full happy-path mock environment.
    # Individual Describe blocks override specific mocks as needed.
    # ---------------------------------------------------------------
    function script:Set-UpdateMocks {

        Mock Start-Transcript { }
        Mock Stop-Transcript  { }

        # sc.exe: counter-based state machine.
        # Uses $global: so the scriptblock (which runs in Pester's module scope)
        # can read and write the counter; $script: would resolve to Pester's
        # internal script scope and is inaccessible from the test file.
        #
        #   call 1 (initial query, Step 1)  → SERVICE_NAME present, RUNNING
        #   call 2 (post-stop wait loop)    → STOPPED  (exits the do/while)
        #   call 3+ (post-start wait loop)  → RUNNING  (exits the do/while)
        $global:osmUpdateScIdx = 0
        Mock 'sc.exe' {
            if ($args -join ' ' -match 'query') {
                $global:osmUpdateScIdx++
                if ($global:osmUpdateScIdx -eq 1) {
                    return @('SERVICE_NAME: OsmUserWeb', 'STATE              : 4  RUNNING')
                }
                if ($global:osmUpdateScIdx -le 2) {
                    return @('SERVICE_NAME: OsmUserWeb', 'STATE              : 1  STOPPED')
                }
                return @('SERVICE_NAME: OsmUserWeb', 'STATE              : 4  RUNNING')
            }
            # sc.exe stop / start / other — succeed silently.
            $global:LASTEXITCODE = 0; return ''
        }

        # netsh: scalar string so -match populates $Matches in the SUT.
        Mock netsh {
            if ($args -join ' ' -match 'show sslcert') {
                return "    Certificate Hash    : AABB1122334455667788990011AABBCCDDEE0000`r`nAppID: {test}"
            }
            $global:LASTEXITCODE = 0; return ''
        }

        # Get-WmiObject: service object with StartName.
        Mock Get-WmiObject {
            [PSCustomObject]@{ StartName = 'DOMAIN\svc-osmweb' }
        }

        # Get-ItemProperty: registry environment carrying HTTPS port 8443.
        Mock Get-ItemProperty {
            [PSCustomObject]@{ Environment = @('ASPNETCORE_URLS=https://+:8443') }
        }

        # Get-ChildItem: discriminate by path.
        #   Cert store path  → empty (no stale self-signed certs).
        #   Publish path     → single fake file object.
        # Pester binds the positional argument as the named $Path parameter;
        # $args[0] may be empty.  Check both $Path and $args[0] to be safe.
        Mock Get-ChildItem {
            $p = if ($Path) { $Path } else { $args[0] }
            if ($p -match 'LocalMachine|Cert:') {
                return @()
            }
            return @(
                [PSCustomObject]@{
                    FullName = "$p\OsmUserWeb.exe"
                    Name     = 'OsmUserWeb.exe'
                }
            )
        }

        # Get-Item: active cert lookup — CA-issued so cleanup is skipped.
        Mock Get-Item {
            [PSCustomObject]@{
                Thumbprint = 'AABB1122334455667788990011AABBCCDDEE0000'
                Subject    = 'CN=osmweb.example.com'
                Issuer     = 'CN=DigiCert CA'
            }
        }

        # Test-Path: return $false for the installed OsmUserWeb.exe at the fake
        # InstallPath (C:\FakeInstall\...) so that the SUT skips the
        # [FileVersionInfo]::GetVersionInfo() call on a non-existent file.
        # All other paths (HKLM registry, TestDrive paths, etc.) return $true.
        Mock Test-Path {
            if ($Path -match 'FakeInstall.*OsmUserWeb\.exe' -or
                $LiteralPath -match 'FakeInstall.*OsmUserWeb\.exe') {
                return $false
            }
            return $true
        }

        # Remove-Item: stub for cert store cleanup assertions.
        Mock Remove-Item { }

        # Copy-Item: stub for binary deployment assertions.
        Mock Copy-Item { }

        # Get-Process: $null (no running process object to wait on).
        Mock Get-Process { $null }

        # Start-Sleep: suppress real waits inside do/while loops.
        Mock Start-Sleep { }

        # curl.exe: simulate HTTP 200 response.
        Mock 'curl.exe' { '200' }

        # Read-Host: default to proceed ('Y').
        Mock Read-Host { 'Y' }

        # Get-EventLog: suppress event log queries on slow-service code paths.
        Mock Get-EventLog { @() }
    }
}

# ── Scenario 1 : Happy path — service RUNNING, port from registry ─────────────

Describe 'Happy path - service RUNNING, port from registry' {

    BeforeAll {
        script:Set-UpdateMocks

        & $script:ScriptPath `
            -PublishPath $script:PublishPath `
            -InstallPath $script:InstallPath `
            -Force
    }

    It 'calls sc.exe stop to stop the running service' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'calls Copy-Item to deploy new binaries' {
        Should -Invoke Copy-Item -Scope Describe
    }

    It 'registers URL ACL via netsh add urlacl' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'add urlacl'
        }
    }

    It 'registers SSL cert binding via netsh add sslcert' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'add sslcert'
        }
    }

    It 'calls sc.exe start to start the service' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }

    It 'probes HTTPS connectivity via curl.exe' {
        Should -Invoke 'curl.exe' -Scope Describe
    }

    It 'reads the HTTPS port from the registry via Get-ItemProperty' {
        Should -Invoke Get-ItemProperty -Scope Describe
    }

    It 'does NOT remove the cert when it is CA-issued (not self-signed)' {
        Should -Invoke Remove-Item -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 2 : Explicit -HttpsPort — registry NOT read ─────────────────────

Describe 'Explicit -HttpsPort supplied - registry not consulted' {

    BeforeAll {
        script:Set-UpdateMocks

        & $script:ScriptPath `
            -PublishPath $script:PublishPath `
            -InstallPath $script:InstallPath `
            -HttpsPort   9443 `
            -Force
    }

    It 'does NOT call Get-ItemProperty when -HttpsPort is supplied' {
        Should -Invoke Get-ItemProperty -Times 0 -Exactly -Scope Describe
    }

    It 'still calls sc.exe start when -HttpsPort is supplied' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }

    It 'still registers URL ACL with the supplied port' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'add urlacl'
        }
    }

    It 'uses the supplied port in the URL ACL registration' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match '9443'
        }
    }
}

# ── Scenario 3 : Service already STOPPED — sc.exe stop NOT called ─────────────

Describe 'Service already STOPPED - stop not called' {

    BeforeAll {
        script:Set-UpdateMocks

        # Override: initial query returns STOPPED; subsequent queries return RUNNING
        # so the post-start wait loop exits cleanly.
        $global:osmUpdateScIdx3 = 0
        Mock 'sc.exe' {
            if ($args -join ' ' -match 'query') {
                $global:osmUpdateScIdx3++
                if ($global:osmUpdateScIdx3 -eq 1) {
                    # Already STOPPED — triggers the 'else' skip-stop branch in SUT.
                    return @('SERVICE_NAME: OsmUserWeb', 'STATE              : 1  STOPPED')
                }
                # Post-start wait: RUNNING immediately.
                return @('SERVICE_NAME: OsmUserWeb', 'STATE              : 4  RUNNING')
            }
            $global:LASTEXITCODE = 0; return ''
        }

        & $script:ScriptPath `
            -PublishPath $script:PublishPath `
            -InstallPath $script:InstallPath `
            -Force
    }

    It 'does NOT call sc.exe stop when service is already STOPPED' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'still calls sc.exe start after skipping the stop step' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }

    It 'still deploys binaries when service was already STOPPED' {
        Should -Invoke Copy-Item -Scope Describe
    }
}

# ── Scenario 4 : Publish path == Install path — Copy-Item NOT called ──────────

Describe 'Publish path equals install path - no copy performed' {

    BeforeAll {
        script:Set-UpdateMocks

        # Pass the same TestDrive publish path as both source and destination.
        # The SUT's TrimEnd('\') comparison will evaluate them equal and skip the copy.
        & $script:ScriptPath `
            -PublishPath $script:PublishPath `
            -InstallPath $script:PublishPath `
            -Force
    }

    It 'does NOT call Copy-Item when publish path equals install path' {
        Should -Invoke Copy-Item -Times 0 -Exactly -Scope Describe
    }

    It 'still calls sc.exe start even when no copy is needed' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }
}

# ── Scenario 5 : No HTTP.sys SSL cert binding — netsh add sslcert NOT called ──

Describe 'No SSL cert binding - sslcert not re-registered' {

    BeforeAll {
        script:Set-UpdateMocks

        # Override: netsh show sslcert returns output with no Certificate Hash.
        Mock netsh {
            if ($args -join ' ' -match 'show sslcert') {
                return 'The system cannot find the file specified.'
            }
            $global:LASTEXITCODE = 0; return ''
        }

        & $script:ScriptPath `
            -PublishPath $script:PublishPath `
            -InstallPath $script:InstallPath `
            -Force
    }

    It 'does NOT call netsh add sslcert when no thumbprint was found' {
        Should -Invoke netsh -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'add sslcert'
        }
    }

    It 'still calls netsh add urlacl even without an SSL cert' {
        Should -Invoke netsh -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'add urlacl'
        }
    }

    It 'does NOT call curl.exe when there is no cert thumbprint' {
        Should -Invoke 'curl.exe' -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 6 : Self-signed cert — stale duplicates removed ──────────────────

Describe 'Self-signed cert - stale duplicates are removed' {

    BeforeAll {
        script:Set-UpdateMocks

        # Override Get-Item: active cert is self-signed (Subject == Issuer == CN=<hostname>).
        Mock Get-Item {
            [PSCustomObject]@{
                Thumbprint = 'AABB1122334455667788990011AABBCCDDEE0000'
                Subject    = "CN=$env:COMPUTERNAME"
                Issuer     = "CN=$env:COMPUTERNAME"
            }
        }

        # Override Get-ChildItem: return a stale self-signed cert when querying the
        # Cert: store, and normal files when querying the publish path.
        # Use $Path (named parameter) as primary discriminator; $args[0] as fallback.
        Mock Get-ChildItem {
            $p = if ($Path) { $Path } else { $args[0] }
            if ($p -match 'LocalMachine|Cert:') {
                return @(
                    [PSCustomObject]@{
                        Thumbprint = 'STALE0000000000000000000000000000000000'
                        Subject    = "CN=$env:COMPUTERNAME"
                        Issuer     = "CN=$env:COMPUTERNAME"
                        NotBefore  = (Get-Date).AddYears(-2)
                    }
                )
            }
            return @(
                [PSCustomObject]@{
                    FullName = "$p\OsmUserWeb.exe"
                    Name     = 'OsmUserWeb.exe'
                }
            )
        }

        & $script:ScriptPath `
            -PublishPath $script:PublishPath `
            -InstallPath $script:InstallPath `
            -Force
    }

    It 'calls Remove-Item targeting the Cert:\LocalMachine store to remove stale certs' {
        Should -Invoke Remove-Item -Scope Describe -ParameterFilter {
            $Path -match 'Cert:\\LocalMachine'
        }
    }

    It 'still completes the update (sc.exe start is called)' {
        Should -Invoke 'sc.exe' -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }
}

# ── Scenario 7 : Service not registered — stops at Step 1 ────────────────────

Describe 'Service not registered - stops at Step 1' {

    BeforeAll {
        script:Set-UpdateMocks

        # Override: sc.exe query returns output with no SERVICE_NAME — not registered.
        # The SUT throws inside try {} which its own catch handles via exit 1.
        # When invoked with &, exit 1 terminates the child scope; no exception reaches
        # the Pester host.  Assertions check that no destructive steps ran.
        Mock 'sc.exe' {
            if ($args -join ' ' -match 'query') {
                return 'The specified service does not exist as an installed service.'
            }
            $global:LASTEXITCODE = 0; return ''
        }

        & $script:ScriptPath `
            -PublishPath $script:PublishPath `
            -InstallPath $script:InstallPath `
            -Force
    }

    It 'does NOT call sc.exe stop when the service is absent' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'stop'
        }
    }

    It 'does NOT call Copy-Item when the service is absent' {
        Should -Invoke Copy-Item -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call sc.exe start when the service is absent' {
        Should -Invoke 'sc.exe' -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'start'
        }
    }
}

# ── Scenario 8 : User aborts at confirmation prompt ───────────────────────────

Describe 'User aborts at confirmation - no changes made' {

    BeforeAll {
        script:Set-UpdateMocks

        # Override: user enters 'N' at the confirmation prompt.
        # The SUT calls exit 0 after the abort message; when invoked with &, this
        # terminates the child scope without affecting the Pester host.
        Mock Read-Host { 'N' }

        $script:threwOnAbort = $false
        try {
            & $script:ScriptPath `
                -PublishPath $script:PublishPath `
                -InstallPath $script:InstallPath
            # No -Force so Read-Host is called
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

    It 'does NOT call Copy-Item after user aborts' {
        Should -Invoke Copy-Item -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call netsh add urlacl after user aborts' {
        Should -Invoke netsh -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -join ' ' -match 'add urlacl'
        }
    }
}
