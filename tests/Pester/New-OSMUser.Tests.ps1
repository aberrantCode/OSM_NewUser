#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for New-OSMUser.ps1.

.DESCRIPTION
    The source script:
      1. Imports the ActiveDirectory module.
      2. Derives a base name from $env:USERNAME (strips trailing digits) or uses -BaseName.
      3. Verifies the target OU exists via Get-ADOrganizationalUnit.
      4. Queries AD for existing numbered accounts via Get-ADUser -Filter.
      5. Computes the next username number.
      6. Gets the domain DNS root via Get-ADDomain.
      7. Prompts for confirmation via Read-Host.
      8. Creates the user via New-ADUser.
      9. Sets CannotChangePassword via Set-ADUser (non-fatal).
     10. Adds to Domain Admins via Add-ADGroupMember (non-fatal).
     11. Verifies the created account via Get-ADUser -Identity.

    Invocation model:
      - `& $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null` runs the SUT.
      - The script uses `return` (not `exit`) for abort path — safe to invoke with &.
      - For throw paths the SUT is wrapped in try/catch and $script:thrownError captured.
      - SUT invoked ONCE per Describe in BeforeAll; It blocks assert only.
      - Should -Invoke uses -Scope Describe throughout.

    Scenarios covered:
      1.  BaseName derived from $env:USERNAME (strips trailing digits: 'erik7' -> 'erik').
      2.  Explicit -BaseName override.
      3.  Empty base name -> throws 'Base name is empty.'
      4.  Next-number with existing accounts (highest = 3 -> creates 4).
      5.  User presses N at confirmation -> New-ADUser NOT called.
      6.  Full happy path: New-ADUser + Set-ADUser + Add-ADGroupMember + verify Get-ADUser.
      7.  Set-ADUser fails non-fatally -> Add-ADGroupMember still called.
      8.  Add-ADGroupMember fails non-fatally -> verify Get-ADUser still called.
      9.  Import-Module fails -> throws.
     10.  Get-ADOrganizationalUnit fails -> throws.
     11.  New-ADUser 'already exists' error -> re-throws.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\PwshScript\New-OSMUser.ps1'

    # ConvertTo-SecureString lives in Microsoft.PowerShell.Security which cannot
    # be autoloaded in this environment.  Declaring a stub function here gives
    # Pester a real command to intercept when Mock is called inside each Describe.
    if (-not (Get-Command ConvertTo-SecureString -ErrorAction SilentlyContinue)) {
        function global:ConvertTo-SecureString {
            param([string]$String, [switch]$AsPlainText, [switch]$Force)
            [System.Security.SecureString]::new()
        }
    }

    function script:Set-CommonAdMocks {
        Mock Import-Module { }
        Mock Get-ADOrganizationalUnit {
            [PSCustomObject]@{ DistinguishedName = 'OU=AdminAccounts,DC=test,DC=local' }
        }
        Mock Get-ADDomain { [PSCustomObject]@{ DNSRoot = 'test.local' } }
        Mock Get-ADUser { @() }
        Mock New-ADUser { }
        Mock Set-ADUser { }
        Mock Add-ADGroupMember { }
        Mock Read-Host { 'Y' }
        Mock ConvertTo-SecureString { [System.Security.SecureString]::new() }
    }
}

# ── Scenario 1: BaseName derived from $env:USERNAME ──────────────────────────

Describe 'BaseName derived from env:USERNAME by stripping trailing digits' {

    BeforeAll {
        $script:savedUsername = $env:USERNAME
        $env:USERNAME = 'erik7'

        Set-CommonAdMocks

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{
                Name = 'erik1'; SamAccountName = 'erik1'
                UserPrincipalName = 'erik1@test.local'
                Enabled = $true; PasswordNeverExpires = $true
                CannotChangePassword = $true; MemberOf = @()
            }
        }

        & $script:ScriptPath -Password 'P@ss1' *>$null
    }

    AfterAll {
        $env:USERNAME = $script:savedUsername
    }

    It 'calls New-ADUser with the username derived from env:USERNAME (erik1)' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $SamAccountName -eq 'erik1'
        }
    }

    It 'calls Import-Module for ActiveDirectory' {
        Should -Invoke Import-Module -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 2: Explicit -BaseName override ───────────────────────────────────

Describe 'Explicit -BaseName override creates correctly named account' {

    BeforeAll {
        Set-CommonAdMocks

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{
                Name = 'admin1'; SamAccountName = 'admin1'
                UserPrincipalName = 'admin1@test.local'
                Enabled = $true; PasswordNeverExpires = $true
                CannotChangePassword = $true; MemberOf = @()
            }
        }

        & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
    }

    It 'calls New-ADUser with SamAccountName derived from the supplied BaseName' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $SamAccountName -eq 'admin1'
        }
    }

    It 'calls Get-ADOrganizationalUnit to verify the target OU' {
        Should -Invoke Get-ADOrganizationalUnit -Times 1 -Exactly -Scope Describe
    }

    It 'calls Get-ADDomain to resolve the DNS root for UPN' {
        Should -Invoke Get-ADDomain -Times 1 -Exactly -Scope Describe
    }

    It 'calls Read-Host to prompt for confirmation' {
        Should -Invoke Read-Host -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 3: Empty base name -> throws ────────────────────────────────────

Describe 'Empty base name throws with appropriate message' {

    BeforeAll {
        $script:savedUsername = $env:USERNAME
        $env:USERNAME = ''
        Set-CommonAdMocks
    }

    AfterAll {
        $env:USERNAME = $script:savedUsername
    }

    It 'throws Base name is empty when env:USERNAME is blank and no -BaseName supplied' {
        { & $script:ScriptPath -Password 'P@ss1' *>$null } | Should -Throw '*Base name is empty*'
    }
}

# ── Scenario 3a: First account (no existing accounts) ────────────────────────

Describe 'First account (no existing accounts creates baseName1)' {

    BeforeAll {
        script:Set-CommonAdMocks   # Get-ADUser already returns @() by default in Set-CommonAdMocks

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{
                Name = 'newadm1'; SamAccountName = 'newadm1'
                UserPrincipalName = 'newadm1@test.local'
                Enabled = $true; PasswordNeverExpires = $true
                CannotChangePassword = $true; MemberOf = @()
            }
        }

        & $script:ScriptPath -BaseName 'newadm' -Password 'P@ss1' *>$null
    }

    It 'creates <baseName>1 when no existing accounts exist' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $SamAccountName -eq 'newadm1'
        }
    }
}

# ── Scenario 4: Next-number with existing accounts (highest = 3) ─────────────

Describe 'Next account number computed correctly when existing accounts found' {

    BeforeAll {
        Set-CommonAdMocks

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) {
                # Simulate existing admin1, admin2, admin3
                return @(
                    [PSCustomObject]@{ SamAccountName = 'admin1' }
                    [PSCustomObject]@{ SamAccountName = 'admin2' }
                    [PSCustomObject]@{ SamAccountName = 'admin3' }
                )
            }
            # Second call: identity lookup for verify step
            return [PSCustomObject]@{
                Name = 'admin4'; SamAccountName = 'admin4'
                UserPrincipalName = 'admin4@test.local'
                Enabled = $true; PasswordNeverExpires = $true
                CannotChangePassword = $true; MemberOf = @()
            }
        }

        & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
    }

    It 'creates admin4 when admin1 through admin3 already exist' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $SamAccountName -eq 'admin4'
        }
    }

    It 'calls Set-ADUser once to set CannotChangePassword on the new account' {
        Should -Invoke Set-ADUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Add-ADGroupMember once to add the new account to Domain Admins' {
        Should -Invoke Add-ADGroupMember -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 5: User presses N at confirmation -> no New-ADUser call ──────────

Describe 'User presses N at confirmation prompt - account creation aborted' {

    BeforeAll {
        Set-CommonAdMocks

        Mock Read-Host { 'N' }

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{ SamAccountName = 'admin1' }
        }

        & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
    }

    It 'does NOT call New-ADUser when user declines confirmation' {
        Should -Invoke New-ADUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Set-ADUser when creation is aborted' {
        Should -Invoke Set-ADUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Add-ADGroupMember when creation is aborted' {
        Should -Invoke Add-ADGroupMember -Times 0 -Exactly -Scope Describe
    }

    It 'calls Read-Host exactly once for the confirmation prompt' {
        Should -Invoke Read-Host -Times 1 -Exactly -Scope Describe
    }
}

# ── Scenario 6: Full happy path ───────────────────────────────────────────────

Describe 'Full happy path - all steps execute successfully' {

    BeforeAll {
        Set-CommonAdMocks

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{
                Name = 'admin1'; SamAccountName = 'admin1'
                UserPrincipalName = 'admin1@test.local'
                Enabled = $true; PasswordNeverExpires = $true
                CannotChangePassword = $true; MemberOf = @()
            }
        }

        & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
    }

    It 'calls Import-Module once' {
        Should -Invoke Import-Module -Times 1 -Exactly -Scope Describe
    }

    It 'calls Get-ADOrganizationalUnit once to verify OU' {
        Should -Invoke Get-ADOrganizationalUnit -Times 1 -Exactly -Scope Describe
    }

    It 'calls Get-ADDomain once to get DNS root' {
        Should -Invoke Get-ADDomain -Times 1 -Exactly -Scope Describe
    }

    It 'calls New-ADUser once with correct parameters' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe -ParameterFilter {
            $SamAccountName -eq 'admin1' -and
            $Enabled -eq $true -and
            $PasswordNeverExpires -eq $true
        }
    }

    It 'calls Set-ADUser once to set CannotChangePassword' {
        Should -Invoke Set-ADUser -Times 1 -Exactly -Scope Describe
    }

    It 'calls Add-ADGroupMember once to add user to Domain Admins' {
        Should -Invoke Add-ADGroupMember -Times 1 -Exactly -Scope Describe
    }

    It 'calls Get-ADUser twice - once for existing accounts, once to verify creation' {
        Should -Invoke Get-ADUser -Times 2 -Exactly -Scope Describe
    }
}

# ── Scenario 7: Set-ADUser fails non-fatally ──────────────────────────────────

Describe 'Set-ADUser failure is non-fatal - Add-ADGroupMember still called' {

    BeforeAll {
        Set-CommonAdMocks

        Mock Write-Host { }
        Mock Set-ADUser { throw 'Access denied setting CannotChangePassword' }

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{
                Name = 'admin1'; SamAccountName = 'admin1'
                UserPrincipalName = 'admin1@test.local'
                Enabled = $true; PasswordNeverExpires = $true
                CannotChangePassword = $false; MemberOf = @()
            }
        }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'does not throw when Set-ADUser fails' {
        $script:thrownError | Should -BeNullOrEmpty
    }

    It 'still calls Add-ADGroupMember after Set-ADUser failure' {
        Should -Invoke Add-ADGroupMember -Times 1 -Exactly -Scope Describe
    }

    It 'still calls Get-ADUser to verify the created account after Set-ADUser failure' {
        Should -Invoke Get-ADUser -Times 2 -Exactly -Scope Describe
    }

    It 'still calls New-ADUser before the non-fatal Set-ADUser failure' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe
    }

    It 'emits a WARNING message when Set-ADUser fails' {
        Should -Invoke Write-Host -Scope Describe -ParameterFilter {
            $Object -match 'WARNING'
        }
    }
}

# ── Scenario 8: Add-ADGroupMember fails non-fatally ──────────────────────────

Describe 'Add-ADGroupMember failure is non-fatal - verify Get-ADUser still called' {

    BeforeAll {
        Set-CommonAdMocks

        Mock Write-Host { }
        Mock Add-ADGroupMember { throw 'Access denied adding to Domain Admins' }

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{
                Name = 'admin1'; SamAccountName = 'admin1'
                UserPrincipalName = 'admin1@test.local'
                Enabled = $true; PasswordNeverExpires = $true
                CannotChangePassword = $true; MemberOf = @()
            }
        }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'does not throw when Add-ADGroupMember fails' {
        $script:thrownError | Should -BeNullOrEmpty
    }

    It 'still calls Get-ADUser to verify the account after Add-ADGroupMember failure' {
        Should -Invoke Get-ADUser -Times 2 -Exactly -Scope Describe
    }

    It 'still calls Set-ADUser before the non-fatal Add-ADGroupMember failure' {
        Should -Invoke Set-ADUser -Times 1 -Exactly -Scope Describe
    }

    It 'emits a WARNING message when Add-ADGroupMember fails' {
        Should -Invoke Write-Host -Scope Describe -ParameterFilter {
            $Object -match 'WARNING'
        }
    }
}

# ── Scenario 9: Import-Module fails -> throws ────────────────────────────────

Describe 'Import-Module failure throws and halts script' {

    BeforeAll {
        Set-CommonAdMocks

        Mock Import-Module { throw 'Module ActiveDirectory not found' }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'throws when the ActiveDirectory module cannot be loaded' {
        $script:thrownError | Should -Not -BeNullOrEmpty
    }

    It 'does NOT call Get-ADOrganizationalUnit after Import-Module failure' {
        Should -Invoke Get-ADOrganizationalUnit -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call New-ADUser after Import-Module failure' {
        Should -Invoke New-ADUser -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 10: Get-ADOrganizationalUnit fails -> throws ────────────────────

Describe 'Get-ADOrganizationalUnit failure throws and halts script' {

    BeforeAll {
        Set-CommonAdMocks

        Mock Get-ADOrganizationalUnit { throw 'OU not found' }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'throws when the target OU does not exist' {
        $script:thrownError | Should -Not -BeNullOrEmpty
    }

    It 'does NOT call New-ADUser after OU lookup failure' {
        Should -Invoke New-ADUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Get-ADUser for existing accounts after OU failure' {
        Should -Invoke Get-ADUser -Times 0 -Exactly -Scope Describe
    }
}

# ── Scenario 11: New-ADUser 'already exists' error -> re-throws ──────────────

Describe 'New-ADUser already exists error is re-thrown' {

    BeforeAll {
        Set-CommonAdMocks

        Mock New-ADUser { throw [System.Exception]::new("The object 'admin1' already exists") }

        $script:getAdUserCallCount = 0
        Mock Get-ADUser {
            $script:getAdUserCallCount++
            if ($script:getAdUserCallCount -eq 1) { return @() }
            return [PSCustomObject]@{ SamAccountName = 'admin1' }
        }

        $script:thrownError = $null
        try {
            & $script:ScriptPath -BaseName 'admin' -Password 'P@ss1' *>$null
        } catch {
            $script:thrownError = $_.Exception.Message
        }
    }

    It 'throws when New-ADUser reports the account already exists' {
        $script:thrownError | Should -Not -BeNullOrEmpty
        $script:thrownError | Should -Match 'already exists'
    }

    It 'does NOT call Set-ADUser after a failed New-ADUser' {
        Should -Invoke Set-ADUser -Times 0 -Exactly -Scope Describe
    }

    It 'does NOT call Add-ADGroupMember after a failed New-ADUser' {
        Should -Invoke Add-ADGroupMember -Times 0 -Exactly -Scope Describe
    }

    It 'calls New-ADUser exactly once before the failure' {
        Should -Invoke New-ADUser -Times 1 -Exactly -Scope Describe
    }
}
