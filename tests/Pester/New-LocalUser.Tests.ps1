#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for New-LocalUser.ps1.

.DESCRIPTION
    The source script:
      1. Checks for admin elevation via Test-IsElevated helper.
      2. Imports PwshSpectreConsole.
      3. Reads .env file for NEW_USER_PASSWORD.
      4. Prompts for password via Read-Host -AsSecureString.
      5. Derives base name from env:USERNAME (strips trailing digits).
      6. Queries local users via Get-LocalUser to compute next username.
      7. Prompts for username via Read-SpectreText.
      8. Validates username is not already in use.
      9. Displays summary panel via Format-SpectrePanel.
     10. Prompts for confirmation via Read-SpectreConfirm.
     11. Creates user via Invoke-SpectreCommandWithStatus wrapping New-LocalUser.
     12. Adds to Administrators via Add-LocalGroupMember.
     13. Verifies creation via Get-LocalUser + Get-LocalGroupMember.
     14. Offers auto-logon prompt via Read-SpectreConfirm.
     15. Writes registry keys via Set-ItemProperty and calls Invoke-Logoff.

    Invocation model:
      - `& $script:ScriptPath *>$null` runs the SUT.
      - The script uses `throw` (not `exit`) for all fatal error paths.
      - For throw paths the SUT is wrapped in try/catch and $script:thrownError captured.
      - SUT invoked ONCE per Describe in BeforeAll; It blocks assert only.
      - Should -Invoke uses -Scope Describe throughout.

    Scenarios covered:
      1.  BaseName derived from env:USERNAME (strips trailing digits: 'erik7' -> 'erik').
      2.  .env file present — password loaded, blank Read-Host accepted.
      3.  No .env file — user enters password; loops once on blank, succeeds second call.
      4.  Password confirm mismatch — Read-Host called again until match.
      5.  Username already in use — Read-SpectreText called again with valid name.
      6.  User aborts at creation confirmation — New-LocalUser NOT called.
      7.  Happy path — all steps succeed, user declines auto-logon.
      8.  Happy path with auto-logon — registry keys written, Invoke-Logoff called.
      9.  Add-LocalGroupMember fails — FATAL: throws after red error message.
     10.  New-LocalUser throws — FATAL: re-throws.
     11.  Not elevated — throws with elevation message.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\Pwsh-NewLocalUser\New-LocalUser.ps1'

    # ── Shared temp .env helpers ──────────────────────────────────────────────
    function script:New-TempEnvFile {
        param([string]$Password = 'EnvP@ssw0rd')
        $script:TempEnvPath = Join-Path $TestDrive '.env'
        Set-Content -Path $script:TempEnvPath -Value "NEW_USER_PASSWORD=$Password"
        return $script:TempEnvPath
    }

    # ── Stub SecureString factory (PS 5.1 compat) ─────────────────────────────
    function script:New-SecureStringStub {
        param([string]$PlainText = 'TestP@ss1')
        $ss = [System.Security.SecureString]::new()
        foreach ($c in $PlainText.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()
        return $ss
    }

    # ── Common mocks applied in every Describe ────────────────────────────────
    function script:Set-CommonLocalUserMocks {
        param(
            [string]$ExpectedUsername  = 'testuser1',
            [string]$EnvFilePath       = '',
            [switch]$ConfirmCreate = $false,
            [switch]$ConfirmLogon  = $false
        )

        # Elevation
        Mock Test-IsElevated { $true }

        # Spectre import (no-op — module already loaded in test session)
        Mock Import-Module { }

        # Spectre output — suppress all display
        Mock Write-SpectreFigletText  { }
        Mock Write-SpectreRule        { }
        Mock Write-SpectreHost        { }
        Mock Format-SpectrePanel      { }
        Mock Format-SpectreTable      { $Input }
        Mock Out-SpectreHost          { }

        # Spectre spinner — must actually run its Task scriptblock
        Mock Invoke-SpectreCommandWithStatus {
            param($Title, $Task, $Spinner, $Color, $SpinnerStyle)
            & $Task
        }

        # Spectre prompts
        Mock Read-SpectreText    { $DefaultValue }
        Mock Read-SpectreConfirm {
            param($Question)
            if ($Question -match 'Log on') { return $ConfirmLogon.IsPresent }
            return $ConfirmCreate.IsPresent
        }

        # .env path resolution — override so script finds our temp file
        Mock Get-EnvFilePath { return $EnvFilePath }

        # Password — Read-Host -AsSecureString returns a matching pair by default
        $ss = script:New-SecureStringStub
        Mock Read-Host { return $ss }

        # Local user cmdlets
        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                if ($Name -eq $ExpectedUsername) {
                    return [PSCustomObject]@{
                        Name               = $ExpectedUsername
                        Enabled            = $true
                        PasswordNeverExpires = $true
                        UserMayNotChangePassword = $true
                    }
                }
                throw "No local user '$Name' was found."
            }
            return @()
        }

        Mock New-LocalUser        { }
        Mock Add-LocalGroupMember { }
        Mock Get-LocalGroupMember {
            @([PSCustomObject]@{ Name = $ExpectedUsername; ObjectClass = 'User' })
        }

        # Registry + logoff
        Mock Set-ItemProperty { }
        Mock Invoke-Logoff    { }
    }
}

# ── Scenario 1: BaseName derived from env:USERNAME ───────────────────────────

Describe 'BaseName derived from env:USERNAME by stripping trailing digits' {

    BeforeAll {
        $script:savedUsername = $env:USERNAME
        $env:USERNAME = 'erik7'

        Set-CommonLocalUserMocks -ExpectedUsername 'erik1'

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                if ($Name -eq 'erik1') {
                    return [PSCustomObject]@{
                        Name = 'erik1'; Enabled = $true
                        PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                    }
                }
                throw "No local user '$Name' was found."
            }
            return @()
        }

        & $script:ScriptPath *>$null
    }

    AfterAll { $env:USERNAME = $script:savedUsername }

    It 'calls New-LocalUser with the username derived from env:USERNAME (erik1)' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Name -eq 'erik1'
        }
    }

    It 'calls Test-IsElevated to check for admin rights' {
        Should -Invoke Test-IsElevated -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 2: .env file present — password loaded, blank accepted ───────────

Describe '.env file present — blank Read-Host response uses env password' {

    BeforeAll {
        $envPath = script:New-TempEnvFile -Password 'EnvSecret1!'
        Set-CommonLocalUserMocks -EnvFilePath $envPath

        Mock Read-Host { [System.Security.SecureString]::new() }

        & $script:ScriptPath *>$null
    }

    It 'calls New-LocalUser (password sourced from .env, not prompt)' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Read-Host exactly once (no confirm needed when using .env value)' {
        Should -Invoke Read-Host -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 3: No .env file — blank loops until password entered ─────────────

Describe 'No .env file — blank password prompt loops until value entered' {

    BeforeAll {
        Set-CommonLocalUserMocks -EnvFilePath ''

        $script:readHostCount = 0
        $blank  = [System.Security.SecureString]::new()
        $filled = script:New-SecureStringStub 'NewP@ss1'

        Mock Read-Host {
            $script:readHostCount++
            if ($script:readHostCount -le 1) { return $blank }
            return $filled
        }

        & $script:ScriptPath *>$null
    }

    It 'calls New-LocalUser after user eventually provides a password' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Read-Host at least 3 times (blank loop + password + confirm)' {
        $script:readHostCount | Should -BeGreaterOrEqual 3
    }
}

# ── Scenario 4: Password confirm mismatch — re-prompts ───────────────────────

Describe 'Password confirm mismatch causes re-prompt until passwords match' {

    BeforeAll {
        Set-CommonLocalUserMocks -EnvFilePath ''

        $script:readHostCount = 0
        $pass1   = script:New-SecureStringStub 'GoodP@ss1'
        $wrong   = script:New-SecureStringStub 'WrongP@ss!'
        $pass2   = script:New-SecureStringStub 'GoodP@ss1'
        $confirm = script:New-SecureStringStub 'GoodP@ss1'

        Mock Read-Host {
            $script:readHostCount++
            switch ($script:readHostCount) {
                1 { return $pass1   }
                2 { return $wrong   }
                3 { return $pass2   }
                4 { return $confirm }
                default { return $confirm }
            }
        }

        & $script:ScriptPath *>$null
    }

    It 'eventually calls New-LocalUser after mismatch is resolved' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Read-Host at least 4 times due to mismatch loop' {
        $script:readHostCount | Should -BeGreaterOrEqual 4
    }
}

# ── Scenario 5: Username already in use — re-prompted ────────────────────────

Describe 'Username already in use causes Read-SpectreText to be called again' {

    BeforeAll {
        Set-CommonLocalUserMocks -ExpectedUsername 'freeuser1'

        $script:spectreTextCount = 0
        Mock Read-SpectreText {
            $script:spectreTextCount++
            if ($script:spectreTextCount -eq 1) { return 'inuseuser' }
            return 'freeuser1'
        }

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                if ($Name -eq 'inuseuser') {
                    return [PSCustomObject]@{ Name = 'inuseuser'; Enabled = $true }
                }
                if ($Name -eq 'freeuser1') {
                    return [PSCustomObject]@{
                        Name = 'freeuser1'; Enabled = $true
                        PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                    }
                }
                throw "No local user '$Name' was found."
            }
            return @()
        }

        & $script:ScriptPath *>$null
    }

    It 'calls Read-SpectreText twice — once for in-use name, once for valid name' {
        $script:spectreTextCount | Should -Be 2
    }

    It 'calls New-LocalUser with the valid (second) username' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Name -eq 'freeuser1'
        }
    }
}

# ── Scenario 6: User aborts at confirmation ───────────────────────────────────

Describe 'User declines confirmation — New-LocalUser is NOT called' {

    BeforeAll {
        Set-CommonLocalUserMocks -ConfirmCreate:$false

        & $script:ScriptPath *>$null
    }

    It 'does NOT call New-LocalUser when user declines' {
        Should -Invoke New-LocalUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Add-LocalGroupMember when creation is aborted' {
        Should -Invoke Add-LocalGroupMember -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ItemProperty when creation is aborted' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 7: Happy path — all steps, no auto-logon ────────────────────────

Describe 'Happy path — all steps succeed, user declines auto-logon' {

    BeforeAll {
        Set-CommonLocalUserMocks -ExpectedUsername 'newadm1' -ConfirmCreate -ConfirmLogon:$false

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                return [PSCustomObject]@{
                    Name = 'newadm1'; Enabled = $true
                    PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                }
            }
            return @()
        }

        & $script:ScriptPath *>$null
    }

    It 'calls Test-IsElevated' {
        Should -Invoke Test-IsElevated -Times 1 -Exactly -Scope Describe
    }

    It 'calls New-LocalUser with PasswordNeverExpires and UserMayNotChangePassword' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Name -eq 'newadm1' -and
            $PasswordNeverExpires -eq $true -and
            $UserMayNotChangePassword -eq $true
        }
    }

    It 'calls Add-LocalGroupMember for the Administrators group' {
        Should -Invoke Add-LocalGroupMember -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $Group -eq 'Administrators' -and $Member -eq 'newadm1'
        }
    }

    It 'calls Get-LocalGroupMember to verify Administrators membership' {
        Should -Invoke Get-LocalGroupMember -Times 1 -Exactly -Scope Describe
    }

    It 'calls Get-LocalUser with the new username to verify creation' {
        Should -Invoke Get-LocalUser -Scope Describe -ParameterFilter {
            $Name -eq 'newadm1'
        }
    }

    It 'does NOT call Set-ItemProperty (auto-logon declined)' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Invoke-Logoff (auto-logon declined)' {
        Should -Invoke Invoke-Logoff -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 8: Happy path WITH auto-logon ───────────────────────────────────

Describe 'Happy path with auto-logon — registry keys written and logoff called' {

    BeforeAll {
        $envPath = script:New-TempEnvFile -Password 'LogonP@ss1'
        Set-CommonLocalUserMocks -ExpectedUsername 'logonuser1' -EnvFilePath $envPath `
            -ConfirmCreate -ConfirmLogon

        Mock Read-Host { [System.Security.SecureString]::new() }

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                return [PSCustomObject]@{
                    Name = 'logonuser1'; Enabled = $true
                    PasswordNeverExpires = $true; UserMayNotChangePassword = $true
                }
            }
            return @()
        }

        & $script:ScriptPath *>$null
    }

    It 'writes AutoAdminLogon registry value' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'AutoAdminLogon' -and $Value -eq '1'
        }
    }

    It 'writes DefaultUserName registry value' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'DefaultUserName' -and $Value -eq 'logonuser1'
        }
    }

    It 'writes DefaultDomainName registry value with computer name' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'DefaultDomainName' -and $Value -eq $env:COMPUTERNAME
        }
    }

    It 'writes AutoLogonCount registry value as 1' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'AutoLogonCount' -and $Value -eq '1'
        }
    }

    It 'writes DefaultPassword registry value with the plain-text password' {
        Should -Invoke Set-ItemProperty -Scope Describe -ParameterFilter {
            $Name -eq 'DefaultPassword' -and $Value -eq 'LogonP@ss1'
        }
    }

    It 'calls Invoke-Logoff to end the current session' {
        Should -Invoke Invoke-Logoff -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 9: Add-LocalGroupMember fails — FATAL ───────────────────────────

Describe 'Add-LocalGroupMember failure is FATAL — script throws' {

    BeforeAll {
        Set-CommonLocalUserMocks -ExpectedUsername 'failgrp1' -ConfirmCreate

        Mock Add-LocalGroupMember { throw 'Access denied adding to Administrators' }

        Mock Get-LocalUser {
            param($Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                return [PSCustomObject]@{ Name = 'failgrp1'; Enabled = $true }
            }
            return @()
        }

        $script:thrownError = $null
        try { & $script:ScriptPath *>$null } catch { $script:thrownError = $_.Exception.Message }
    }

    It 'throws when Add-LocalGroupMember fails' {
        $script:thrownError | Should -Not -BeNullOrEmpty
        $script:thrownError | Should -Match 'Access denied'
    }

    It 'calls New-LocalUser before the fatal group-add failure' {
        Should -Invoke New-LocalUser -Times 1 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ItemProperty after a fatal group-add failure' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 10: New-LocalUser throws — FATAL ─────────────────────────────────

Describe 'New-LocalUser failure is FATAL — script re-throws' {

    BeforeAll {
        Set-CommonLocalUserMocks -ConfirmCreate

        Mock New-LocalUser { throw [System.Exception]::new('The user account already exists') }

        $script:thrownError = $null
        try { & $script:ScriptPath *>$null } catch { $script:thrownError = $_.Exception.Message }
    }

    It 'throws when New-LocalUser fails' {
        $script:thrownError | Should -Not -BeNullOrEmpty
        $script:thrownError | Should -Match 'already exists'
    }

    It 'does NOT call Add-LocalGroupMember after New-LocalUser failure' {
        Should -Invoke Add-LocalGroupMember -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ItemProperty after New-LocalUser failure' {
        Should -Invoke Set-ItemProperty -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 11: Not elevated — throws ────────────────────────────────────────

Describe 'Not elevated — throws with elevation error message' {

    BeforeAll {
        Set-CommonLocalUserMocks
        Mock Test-IsElevated { $false }

        $script:thrownError = $null
        try { & $script:ScriptPath *>$null } catch { $script:thrownError = $_.Exception.Message }
    }

    It 'throws when not running as Administrator' {
        $script:thrownError | Should -Not -BeNullOrEmpty
        $script:thrownError | Should -Match '(?i)administrator'
    }

    It 'does NOT call New-LocalUser when not elevated' {
        Should -Invoke New-LocalUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Import-Module when not elevated' {
        Should -Invoke Import-Module -Times 0 -Exactly -Scope Describe
    }
}
