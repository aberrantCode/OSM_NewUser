#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for the shared helper functions in ScriptHelpers.ps1.
#>

# Dot-source the module under test so its functions are available in this scope.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\src\DotNet-DomainWebServer\ScriptHelpers.ps1')
}

# ── Read-WithDefault ─────────────────────────────────────────────────────────

Describe 'Read-WithDefault' {

    It 'returns the default when the user presses Enter (empty input)' {
        Mock Read-Host { return '' }
        Read-WithDefault 'My prompt' 'MyDefault' | Should -Be 'MyDefault'
    }

    It 'returns the default when the user enters only whitespace' {
        Mock Read-Host { return '   ' }
        Read-WithDefault 'My prompt' 'MyDefault' | Should -Be 'MyDefault'
    }

    It 'returns the user input when it is non-empty' {
        Mock Read-Host { return 'UserValue' }
        Read-WithDefault 'My prompt' 'MyDefault' | Should -Be 'UserValue'
    }

    It 'trims leading and trailing whitespace from user input' {
        Mock Read-Host { return '  trimmed  ' }
        Read-WithDefault 'My prompt' 'MyDefault' | Should -Be 'trimmed'
    }

    It 'passes the bracketed default to Read-Host' {
        Mock Read-Host { return '' }
        Read-WithDefault 'Path' 'C:\Services\OsmUserWeb'
        Should -Invoke Read-Host -Times 1 -ParameterFilter {
            $Prompt -eq 'Path [C:\Services\OsmUserWeb]'
        }
    }
}

# ── Read-NonEmpty ─────────────────────────────────────────────────────────────

Describe 'Read-NonEmpty' {

    It 'returns the value immediately when first input is non-empty' {
        Mock Read-Host { return 'FirstInput' }
        Read-NonEmpty 'My prompt' | Should -Be 'FirstInput'
    }

    It 'retries and returns the second input when first is empty' {
        $script:callCount = 0
        Mock Read-Host {
            $script:callCount++
            if ($script:callCount -eq 1) { return '' } else { return 'SecondInput' }
        }
        Read-NonEmpty 'My prompt' | Should -Be 'SecondInput'
        Should -Invoke Read-Host -Times 2
    }

    It 'retries when input is only whitespace' {
        $script:callCount = 0
        Mock Read-Host {
            $script:callCount++
            if ($script:callCount -eq 1) { return '   ' } else { return 'ValidInput' }
        }
        Read-NonEmpty 'My prompt' | Should -Be 'ValidInput'
    }

    It 'trims the returned value' {
        Mock Read-Host { return '  hello  ' }
        Read-NonEmpty 'My prompt' | Should -Be 'hello'
    }
}
