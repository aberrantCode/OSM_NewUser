#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for install.ps1 (the remote installer / self-updater).

.DESCRIPTION
    install.ps1 stages a freshly downloaded release in TEMP, then swaps it into
    $InstallDir (C:\osm\new-localuser). The swap is performed by Set-InstallPayload.

    These tests dot-source install.ps1 to load Set-InstallPayload WITHOUT running
    the installer body (the script returns early when dot-sourced).

    Regression coverage for the "directory in use" update failure:
        When the launcher (Start-App.ps1) self-updates, it runs from INSIDE
        $InstallDir, so $InstallDir is the running process's current working
        directory. Windows refuses to delete a directory that is a running
        process's current directory ("Cannot remove the item ... because it is
        in use"). Set-InstallPayload must therefore replace the directory's
        *contents* in place rather than deleting and recreating the directory.

        The in-place requirement is verified faithfully by running the swap in a
        child process whose working directory IS the install directory — the only
        way to reproduce the OS-level lock, which depends on the process being
        started with that working directory.
#>

BeforeAll {
    $script:InstallScript = (Resolve-Path (Join-Path $PSScriptRoot '..\..\install.ps1')).Path

    # Dot-source to load Set-InstallPayload; the installer body returns early
    # when dot-sourced, so no network/elevation code runs here.
    . $script:InstallScript

    $script:PwshExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
}

Describe 'Set-InstallPayload' {

    It 'is defined by dot-sourcing install.ps1' {
        Get-Command Set-InstallPayload -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'first-time install (install directory does not exist)' {

        BeforeAll {
            $script:install = Join-Path $TestDrive 'first\new-localuser'   # parent does not exist
            $script:source  = Join-Path $TestDrive 'staging-first\payload'
            New-Item -ItemType Directory -Path $script:source -Force | Out-Null
            Set-Content -Path (Join-Path $script:source 'a.txt') -Value 'new' -Encoding UTF8

            Set-InstallPayload -SourceDir $script:source -InstallDir $script:install
        }

        It 'creates the install directory (including missing parents)' {
            Test-Path $script:install | Should -BeTrue
        }

        It 'moves the payload contents into the install directory' {
            Get-Content (Join-Path $script:install 'a.txt') -Raw | Should -Match 'new'
        }
    }

    Context 'update over an existing install (in place, dir not locked)' {

        BeforeAll {
            $script:install = Join-Path $TestDrive 'upd\new-localuser'
            New-Item -ItemType Directory -Path $script:install -Force | Out-Null
            Set-Content -Path (Join-Path $script:install 'old.txt') -Value 'old' -Encoding UTF8

            $script:source = Join-Path $TestDrive 'staging-upd\payload'
            New-Item -ItemType Directory -Path $script:source -Force | Out-Null
            Set-Content -Path (Join-Path $script:source 'new.txt') -Value 'new' -Encoding UTF8

            Set-InstallPayload -SourceDir $script:source -InstallDir $script:install
        }

        It 'removes the previous contents' {
            Test-Path (Join-Path $script:install 'old.txt') | Should -BeFalse
        }

        It 'installs the new contents' {
            Test-Path (Join-Path $script:install 'new.txt') | Should -BeTrue
        }
    }

    Context 'update while the install directory is the running process working directory' {

        BeforeAll {
            $script:install = Join-Path $TestDrive 'locked\new-localuser'
            New-Item -ItemType Directory -Path $script:install -Force | Out-Null
            Set-Content -Path (Join-Path $script:install 'old.txt') -Value 'old' -Encoding UTF8

            $script:source = Join-Path $TestDrive 'staging-locked\payload'
            New-Item -ItemType Directory -Path $script:source -Force | Out-Null
            Set-Content -Path (Join-Path $script:source 'new.txt') -Value 'new' -Encoding UTF8

            # Run the swap in a child process whose CWD is the install dir. This
            # reproduces the exact self-update scenario and the OS-level lock.
            $cmd = ". `"$script:InstallScript`"; " +
                   "try { Set-InstallPayload -SourceDir `"$script:source`" -InstallDir `"$script:install`"; exit 0 } " +
                   "catch { Write-Error `$_; exit 1 }"

            $script:proc = Start-Process -FilePath $script:PwshExe `
                -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd `
                -WorkingDirectory $script:install `
                -Wait -PassThru -WindowStyle Hidden
        }

        It 'completes without the "directory in use" failure' {
            $script:proc.ExitCode | Should -Be 0
        }

        It 'installs the new contents' {
            Test-Path (Join-Path $script:install 'new.txt') | Should -BeTrue
        }

        It 'removes the previous contents' {
            Test-Path (Join-Path $script:install 'old.txt') | Should -BeFalse
        }
    }
}
