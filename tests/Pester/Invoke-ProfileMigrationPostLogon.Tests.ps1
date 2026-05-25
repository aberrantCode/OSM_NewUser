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
            if ("$Path" -eq 'C:\tmp\cfg\ProfileMigrationPatterns.json') { return $true }
            if ("$Path" -eq 'C:\tmp\users\olduser\Videos\ManyCam') { return $true }
            if ("$Path" -eq 'C:\tmp\users\newuser\Videos\ManyCam') { return $false }
            if ("$Path" -eq 'C:\tmp\logs') { return $true }
            return $false
        }

        Mock Get-Content {
            param($Path, [switch]$Raw)
            if ("$Path" -eq 'C:\tmp\cfg\ProfileMigrationPatterns.json') {
                return '[{"RelativePath":"Videos\\ManyCam","Pattern":"*.mp4","Recurse":false}]'
            }
            return ''
        }

        Mock Get-ChildItem {
            param($Path, $Filter, [switch]$File, [switch]$Recurse)
            if ("$Path" -eq 'C:\tmp\users\olduser\Videos\ManyCam' -and $Filter -eq '*.mp4') {
                return @([PSCustomObject]@{
                    FullName = 'C:\tmp\users\olduser\Videos\ManyCam\clip_20240501.mp4'
                    BaseName = 'clip_20240501'
                    Extension = '.mp4'
                    CreationTime = [datetime]'2024-05-01T10:30:00'
                })
            }
            return @()
        }

        & $script:ScriptPath `
            -PreviousUserName 'olduser' `
            -NewUserName 'newuser' `
            -ConfigPath 'C:\tmp\cfg\ProfileMigrationPatterns.json' `
            -PreviousUserProfilePath 'C:\tmp\users\olduser' `
            -NewUserProfilePath 'C:\tmp\users\newuser' `
            -LogPath 'C:\tmp\logs\migration.log'
    }

    It 'grants ACLs through icacls before migration copy' {
        Should -Invoke Start-Process -Scope Describe -ParameterFilter {
            $FilePath -eq 'icacls.exe'
        } -Times 1 -Exactly
    }

    It 'copies matching files into the new profile path' {
        Should -Invoke Copy-Item -Scope Describe -ParameterFilter {
            $Path -eq 'C:\tmp\users\olduser\Videos\ManyCam\clip_20240501.mp4' -and
            $Destination -eq 'C:\tmp\users\newuser\Videos\ManyCam\olduser - ManyCam - clip - 2024-05-01.mp4'
        } -Times 1 -Exactly
    }

    It 'appends a per-file migration ledger row in the new profile' {
        Should -Invoke Add-Content -Scope Describe -ParameterFilter {
            $Path -eq 'C:\tmp\users\newuser\Documents\OSM_ProfileMigrationLog.csv' -and
            "$Value" -like '"*clip_20240501.mp4","*olduser - ManyCam - clip - 2024-05-01.mp4","*"'
        } -Times 1 -Exactly
    }

    It 'prompts to remove the previous user and removes when confirmed' {
        Should -Invoke Read-Host -Times 1 -Exactly -Scope Describe
        Should -Invoke Remove-LocalUser -Scope Describe -ParameterFilter {
            $Name -eq 'olduser'
        } -Times 1 -Exactly
    }
}

Describe 'Invoke-ProfileMigrationPostLogon resolves destination name collisions' {
    BeforeAll {
        Mock Test-IsElevated { $true }
        Mock Add-Content { }
        Mock Write-Host { }
        Mock New-Item { }
        Mock Copy-Item { }
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }

        Mock Test-Path {
            param($Path, $PathType)
            if ("$Path" -eq 'C:\tmp\cfg\ProfileMigrationPatterns.json') { return $true }
            if ("$Path" -eq 'C:\tmp\users\olduser\Documents\ShareX\Screenshots') { return $true }
            if ("$Path" -like '*olduser - ShareX - Screenshots - clip - 2025-11-30.mp4') { return $true }
            if ("$Path" -like '*olduser - ShareX - Screenshots - clip - 2025-11-30 1.mp4') { return $false }
            return $false
        }

        Mock Get-Content {
            param($Path, [switch]$Raw)
            if ("$Path" -eq 'C:\tmp\cfg\ProfileMigrationPatterns.json') {
                return '[{"RelativePath":"Documents\\ShareX\\Screenshots","Pattern":"*.mp4","Recurse":true}]'
            }
            return ''
        }

        Mock Get-ChildItem {
            param($Path, $Filter, [switch]$File, [switch]$Recurse)
            if ("$Path" -eq 'C:\tmp\users\olduser\Documents\ShareX\Screenshots' -and $Filter -eq '*.mp4') {
                return @([PSCustomObject]@{
                    FullName = 'C:\tmp\users\olduser\Documents\ShareX\Screenshots\2025-11\clip-20251130.mp4'
                    BaseName = 'clip-20251130'
                    Extension = '.mp4'
                    CreationTime = [datetime]'2025-11-30T09:00:00'
                })
            }
            return @()
        }

        & $script:ScriptPath `
            -PreviousUserName 'olduser' `
            -NewUserName 'newuser' `
            -ConfigPath 'C:\tmp\cfg\ProfileMigrationPatterns.json' `
            -PreviousUserProfilePath 'C:\tmp\users\olduser' `
            -NewUserProfilePath 'C:\tmp\users\newuser' `
            -LogPath 'C:\tmp\logs\migration.log' `
            -SkipRemovalPrompt `
            -NonInteractive
    }

    It 'adds an increment after the date when the formulated destination exists' {
        Should -Invoke Copy-Item -Scope Describe -ParameterFilter {
            $Destination -eq 'C:\tmp\users\newuser\Documents\ShareX\Screenshots\2025-11\olduser - ShareX - Screenshots - clip - 2025-11-30 1.mp4'
        } -Times 1 -Exactly
    }
}
