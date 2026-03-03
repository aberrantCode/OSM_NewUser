#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Start-OsmUserWeb.ps1.

.DESCRIPTION
    The source script:
      1. Calls `& dotnet --list-sdks` to check for a .NET 9 SDK.
      2. If SDK absent: checks Get-Command winget, runs `winget install`, checks
         $LASTEXITCODE, refreshes $env:PATH.
      3. If -NoBrowser not set: calls Start-Job to open a browser after 2s.
      4. Calls Push-Location / dotnet run / Pop-Location (in try/finally).

    Invocation model:
      - `& $script:ScriptPath -NoBrowser *>$null` runs the SUT in a child scope.
        The script has NO `exit` statements, so the Pester host is unaffected.
      - Pester mocks registered in BeforeAll are active when & runs.
      - The SUT is invoked ONCE per Describe in BeforeAll; It blocks assert only.
      - $global:LASTEXITCODE is set inside Mock bodies to simulate native-command
        exit codes that the SUT checks with $LASTEXITCODE.
      - Should -Invoke with -ParameterFilter and -Times N -Exactly is used
        throughout; no $script: counters inside Mock bodies (they write to the
        Pester module scope, not the test-file scope).

    Scenarios covered:
      1. SDK found    — dotnet --list-sdks returns a 9.x line; winget skipped;
                        Push-Location / Pop-Location called; dotnet run called.
      2. -NoBrowser   — Start-Job NOT called.
      3. No -NoBrowser — Start-Job called once.
      4. SDK absent, winget succeeds — winget install called; dotnet run proceeds.
      5. SDK absent, winget absent   — Get-Command winget returns $null; throws.
      6. SDK absent, winget fails    — winget exits non-zero; throws.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\DotNet-DomainWebServer\Start-OsmUserWeb.ps1'
}

# ── Scenario 1 : SDK found ────────────────────────────────────────────────────

Describe 'SDK found - happy path' {

    BeforeAll {
        Mock dotnet {
            if ($args -contains '--list-sdks') {
                return '9.0.100 [C:\Program Files\dotnet\sdk]'
            }
            # dotnet run — return immediately (server exits at once in test context)
            return ''
        }
        Mock winget {}
        Mock Get-Command {}
        Mock Push-Location {}
        Mock Pop-Location {}
        Mock Start-Job { return [PSCustomObject]@{ Id = 1; State = 'Running' } }

        & $script:ScriptPath -NoBrowser *>$null
    }

    It 'calls dotnet --list-sdks to check for the SDK' {
        Should -Invoke dotnet -Scope Describe -ParameterFilter {
            $args -contains '--list-sdks'
        }
    }

    It 'does NOT call winget when the SDK is already present' {
        Should -Invoke winget -Times 0 -Exactly -Scope Describe
    }

    It 'calls Push-Location once before starting the server' {
        Should -Invoke Push-Location -Times 1 -Exactly -Scope Describe
    }

    It 'calls Pop-Location once (finally block)' {
        Should -Invoke Pop-Location -Times 1 -Exactly -Scope Describe
    }

    It 'calls dotnet run to start the server' {
        Should -Invoke dotnet -Scope Describe -ParameterFilter {
            $args -notcontains '--list-sdks'
        }
    }
}

# ── Scenario 2 : -NoBrowser suppresses Start-Job ─────────────────────────────

Describe '-NoBrowser flag suppresses browser launch' {

    BeforeAll {
        Mock dotnet {
            if ($args -contains '--list-sdks') {
                return '9.0.100 [C:\Program Files\dotnet\sdk]'
            }
            return ''
        }
        Mock Push-Location {}
        Mock Pop-Location {}
        Mock Start-Job { return [PSCustomObject]@{ Id = 1; State = 'Running' } }

        & $script:ScriptPath -NoBrowser *>$null
    }

    It 'does NOT call Start-Job when -NoBrowser is specified' {
        Should -Invoke Start-Job -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 3 : No -NoBrowser → browser job is launched ─────────────────────

Describe 'No -NoBrowser flag launches browser job' {

    BeforeAll {
        Mock dotnet {
            if ($args -contains '--list-sdks') {
                return '9.0.100 [C:\Program Files\dotnet\sdk]'
            }
            return ''
        }
        Mock Push-Location {}
        Mock Pop-Location {}
        Mock Start-Job { return [PSCustomObject]@{ Id = 1; State = 'Running' } }

        & $script:ScriptPath *>$null
    }

    It 'calls Start-Job exactly once to schedule the browser open' {
        Should -Invoke Start-Job -Times 1 -Exactly -Scope Describe
    }

    It 'passes the server URL as an argument to Start-Job' {
        Should -Invoke Start-Job -Scope Describe -ParameterFilter {
            $ArgumentList -contains 'http://localhost:5150'
        }
    }
}

# ── Scenario 4 : SDK absent, winget succeeds ─────────────────────────────────

Describe 'SDK absent - winget installs successfully' {

    BeforeAll {
        Mock dotnet {
            if ($args -contains '--list-sdks') {
                # Return a 7.x line — no 9.x SDK present
                return '7.0.100 [C:\Program Files\dotnet\sdk]'
            }
            return ''
        }
        Mock Get-Command {
            return [PSCustomObject]@{ Name = 'winget'; CommandType = 'Application' }
        }
        Mock winget {
            $global:LASTEXITCODE = 0
        }
        Mock Push-Location {}
        Mock Pop-Location {}
        Mock Start-Job { return [PSCustomObject]@{ Id = 1; State = 'Running' } }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -NoBrowser *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'does not throw when winget install exits 0' {
        $script:thrownError | Should -BeNullOrEmpty
    }

    It 'calls winget install with the .NET 9 SDK package ID' {
        Should -Invoke winget -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $args -contains '--id' -and $args -contains 'Microsoft.DotNet.SDK.9'
        }
    }

    It 'proceeds to call dotnet run after successful install' {
        Should -Invoke dotnet -Scope Describe -ParameterFilter {
            $args -notcontains '--list-sdks'
        }
    }

    It 'calls Push-Location once' {
        Should -Invoke Push-Location -Times 1 -Exactly -Scope Describe
    }

    It 'calls Pop-Location once' {
        Should -Invoke Pop-Location -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 5 : SDK absent, winget not found ─────────────────────────────────

Describe 'SDK absent - winget not found on machine' {

    BeforeAll {
        Mock dotnet {
            if ($args -contains '--list-sdks') {
                # Simulate dotnet not on PATH at all by returning empty
                return ''
            }
            return ''
        }
        # Get-Command returns $null → winget unavailable
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'winget' }
        Mock winget {}
        Mock Push-Location {}
        Mock Pop-Location {}
        Mock Start-Job { return [PSCustomObject]@{ Id = 1; State = 'Running' } }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -NoBrowser *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'throws the expected winget-not-found message' {
        $script:thrownError | Should -Be 'winget not found.'
    }

    It 'does NOT call winget install when winget is unavailable' {
        Should -Invoke winget -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call dotnet run when the SDK cannot be installed' {
        Should -Invoke dotnet -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -notcontains '--list-sdks'
        }
    }
}

# ── Scenario 6 : SDK absent, winget exits non-zero ───────────────────────────

Describe 'SDK absent - winget install fails with non-zero exit code' {

    BeforeAll {
        Mock dotnet {
            if ($args -contains '--list-sdks') {
                return ''
            }
            return ''
        }
        Mock Get-Command {
            return [PSCustomObject]@{ Name = 'winget'; CommandType = 'Application' }
        }
        Mock winget {
            $global:LASTEXITCODE = 1
        }
        Mock Push-Location {}
        Mock Pop-Location {}
        Mock Start-Job { return [PSCustomObject]@{ Id = 1; State = 'Running' } }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -NoBrowser *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'throws a message containing the winget exit code' {
        $script:thrownError | Should -Match 'winget exited with code'
    }

    It 'throws a message that includes the non-zero exit code value' {
        $script:thrownError | Should -Match '1'
    }

    It 'calls winget install exactly once before failing' {
        Should -Invoke winget -Times 1 -Exactly -Scope Describe
    }

    It 'does NOT call dotnet run after a failed winget install' {
        Should -Invoke dotnet -Times 0 -Exactly -Scope Describe -ParameterFilter {
            $args -notcontains '--list-sdks'
        }
    }
}
