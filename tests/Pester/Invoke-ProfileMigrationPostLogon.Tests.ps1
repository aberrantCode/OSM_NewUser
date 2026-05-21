#Requires -Version 5.1

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\Pwsh-NewLocalUser\Invoke-ProfileMigrationPostLogon.ps1'

    function script:Test-IsElevated { $true }
    function script:Remove-LocalUser { param([string]$Name) }
}

Describe 'Invoke-ProfileMigrationPostLogon auto-elevates when needed' {
    BeforeAll {
        Mock Test-IsElevated { $false }
        Mock Start-Process { }

        & $script:ScriptPath -PreviousUserName 'olduser' -NewUserName 'newuser' -NonInteractive -SkipRemovalPrompt
    }

    It 'starts an elevated PowerShell process and exits' {
        Should -Invoke Start-Process -Scope Describe -ParameterFilter {
            $FilePath -eq 'powershell.exe' -and $Verb -eq 'RunAs'
        } -Times 1 -Exactly
    }
}

Describe 'Invoke-ProfileMigrationPostLogon copies matching files and can remove previous user' {
    BeforeAll {
        Mock Test-IsElevated { $true }
        Mock Add-Content { }
        Mock Write-Host { }
        Mock New-Item { }
        Mock Copy-Item { }
        Mock Remove-LocalUser { }
        Mock Read-Host { 'Y' }
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }

        Mock Test-Path {
            param($Path, $PathType)
            if ("$Path" -eq '/tmp/cfg/ProfileMigrationPatterns.json') { return $true }
            if ("$Path" -eq '/tmp/users/olduser/Videos/ManyCam') { return $true }
            if ("$Path" -eq '/tmp/users/newuser/Videos/ManyCam') { return $false }
            if ("$Path" -eq '/tmp/logs') { return $true }
            return $false
        }

        Mock Get-Content {
            param($Path, [switch]$Raw)
            if ("$Path" -eq '/tmp/cfg/ProfileMigrationPatterns.json') {
                return '[{"RelativePath":"Videos/ManyCam","Pattern":"*.mp4","Recurse":false}]'
            }
            return ''
        }

        Mock Get-ChildItem {
            param($Path, $Filter, [switch]$File, [switch]$Recurse)
            if ("$Path" -eq '/tmp/users/olduser/Videos/ManyCam' -and $Filter -eq '*.mp4') {
                return @([PSCustomObject]@{ FullName = '/tmp/users/olduser/Videos/ManyCam/clip.mp4' })
            }
            return @()
        }

        & $script:ScriptPath `
            -PreviousUserName 'olduser' `
            -NewUserName 'newuser' `
            -ConfigPath '/tmp/cfg/ProfileMigrationPatterns.json' `
            -PreviousUserProfilePath '/tmp/users/olduser' `
            -NewUserProfilePath '/tmp/users/newuser' `
            -LogPath '/tmp/logs/migration.log'
    }

    It 'grants ACLs through icacls before migration copy' {
        Should -Invoke Start-Process -Scope Describe -ParameterFilter {
            $FilePath -eq 'icacls.exe'
        } -Times 1 -Exactly
    }

    It 'copies matching files into the new profile path' {
        Should -Invoke Copy-Item -Scope Describe -ParameterFilter {
            $Path -eq '/tmp/users/olduser/Videos/ManyCam/clip.mp4' -and
            $Destination -eq '/tmp/users/newuser/Videos/ManyCam/clip.mp4'
        } -Times 1 -Exactly
    }

    It 'prompts to remove the previous user and removes when confirmed' {
        Should -Invoke Read-Host -Times 1 -Exactly -Scope Describe
        Should -Invoke Remove-LocalUser -Scope Describe -ParameterFilter {
            $Name -eq 'olduser'
        } -Times 1 -Exactly
    }
}
