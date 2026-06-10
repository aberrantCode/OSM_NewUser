#Requires -Version 5.1
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\src\Pwsh-NewLocalUser\ConsoleUI.ps1')
}

Describe 'ConvertFrom-AppMarkup' {
    It 'maps grey to DarkGray and strips the tags' {
        $r = ConvertFrom-AppMarkup '[grey]hello[/]'
        $r.Text  | Should -Be 'hello'
        $r.Color | Should -Be ([System.ConsoleColor]::DarkGray)
    }
    It 'uses the outer color and strips inner tags for nested markup' {
        $r = ConvertFrom-AppMarkup '[grey]press [bold]Enter[/] now[/]'
        $r.Text  | Should -Be 'press Enter now'
        $r.Color | Should -Be ([System.ConsoleColor]::DarkGray)
    }
    It 'returns null color when there is no recognized markup' {
        $r = ConvertFrom-AppMarkup 'Password: '
        $r.Text  | Should -Be 'Password: '
        $r.Color | Should -Be $null
    }
}

Describe 'Write-AppHost' {
    It 'renders the stripped text in the mapped color' {
        Mock Write-Host {}
        Write-AppHost '[yellow]warn[/]'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq 'warn' -and $ForegroundColor -eq [System.ConsoleColor]::Yellow
        }
    }
    It 'passes -NoNewline through and uses no color for plain text' {
        Mock Write-Host {}
        Write-AppHost 'Password: ' -NoNewline
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq 'Password: ' -and $NoNewline -eq $true -and $null -eq $ForegroundColor
        }
    }
}

Describe 'Read-AppConfirm (default Yes)' {
    It 'returns true on blank input' {
        Mock Read-Host { '' }
        Read-AppConfirm -Message 'ok?' | Should -BeTrue
    }
    It 'returns true on y' {
        Mock Read-Host { 'y' }
        Read-AppConfirm -Message 'ok?' | Should -BeTrue
    }
    It 'returns false on n' {
        Mock Read-Host { 'n' }
        Read-AppConfirm -Message 'ok?' | Should -BeFalse
    }
}

Describe 'Read-AppText' {
    It 'returns the default on blank input' {
        Mock Read-Host { '' }
        Read-AppText -Message 'Username' -DefaultAnswer 'erik2' | Should -Be 'erik2'
    }
    It 'returns the entered value when provided' {
        Mock Read-Host { 'custom' }
        Read-AppText -Message 'Username' -DefaultAnswer 'erik2' | Should -Be 'custom'
    }
}

Describe 'Show-AppSummary' {
    It 'prints the header and indents each data line' {
        Mock Write-Host {}
        Show-AppSummary -Header 'Summary' -Data "a : 1`nb : 2"
        Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Summary' }
        Should -Invoke Write-Host -ParameterFilter { $Object -eq '  a : 1' }
        Should -Invoke Write-Host -ParameterFilter { $Object -eq '  b : 2' }
    }
}

Describe 'Invoke-AppStatus' {
    It 'runs the scriptblock' {
        Mock Write-Host {}
        $script:ran = $false
        Invoke-AppStatus -Title 'working' -ScriptBlock { $script:ran = $true }
        $script:ran | Should -BeTrue
    }
}
