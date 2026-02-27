#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new numbered admin account in Active Directory.

.DESCRIPTION
    Derives a base name from the current user (or -BaseName override), finds the
    highest existing numbered account, and creates the next one in the target OU
    with Domain Admins membership.

.PARAMETER BaseName
    Override the base name. Default: current username with trailing digits stripped.

.PARAMETER Password
    Override the account password. Default: value in the configuration section below.

.EXAMPLE
    .\New-OSMUser.ps1
    .\New-OSMUser.ps1 -BaseName "admin" -Password "S0meP@ss!" -Verbose
#>
[CmdletBinding()]
param(
    [string]$BaseName,
    [string]$Password
)

$ErrorActionPreference = 'Stop'

# ── Configuration ────────────────────────────────────────────────────────────
$DefaultPassword = 'YourDefaultP@ssw0rd'
$TargetOU        = 'OU=AdminAccounts,DC=yourdomain,DC=com'
$GroupName       = 'Domain Admins'
# ─────────────────────────────────────────────────────────────────────────────

# ── Step 1: Import Active Directory module ───────────────────────────────────
Write-Verbose 'Importing ActiveDirectory module...'
try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Host 'ERROR: Could not load the ActiveDirectory module.' -ForegroundColor Red
    Write-Host 'Install RSAT: Install-WindowsFeature RSAT-AD-PowerShell  (Server)' -ForegroundColor Red
    Write-Host '       or:   Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools  (Win10/11)' -ForegroundColor Red
    throw
}
Write-Verbose 'ActiveDirectory module loaded.'

# ── Step 2: Resolve base name ───────────────────────────────────────────────
if (-not $BaseName) {
    $BaseName = $env:USERNAME -replace '\d+$', ''
    Write-Verbose "Derived base name from `$env:USERNAME ('$env:USERNAME'): '$BaseName'"
}
else {
    Write-Verbose "Using supplied base name: '$BaseName'"
}

if ([string]::IsNullOrWhiteSpace($BaseName)) {
    Write-Host 'ERROR: Base name resolved to an empty string. Use -BaseName to specify one.' -ForegroundColor Red
    throw 'Base name is empty.'
}

# ── Step 3: Resolve password ────────────────────────────────────────────────
if (-not $Password) {
    $Password = $DefaultPassword
    Write-Verbose 'Using default password from configuration section.'
}
else {
    Write-Verbose 'Using supplied password override.'
}

# ── Step 4: Verify target OU exists ─────────────────────────────────────────
Write-Verbose "Verifying target OU: $TargetOU"
try {
    $null = Get-ADOrganizationalUnit -Identity $TargetOU -ErrorAction Stop
}
catch {
    Write-Host "ERROR: Target OU not found: $TargetOU" -ForegroundColor Red
    Write-Host 'Update the $TargetOU variable in the configuration section of this script.' -ForegroundColor Red
    throw
}
Write-Verbose 'Target OU verified.'

# ── Step 5: Query AD for existing numbered accounts ─────────────────────────
Write-Verbose "Searching for accounts matching '$BaseName*'..."
$existing = Get-ADUser -Filter "SamAccountName -like '$BaseName*'" -Properties SamAccountName |
    Where-Object { $_.SamAccountName -match "^$([regex]::Escape($BaseName))(\d+)$" } |
    ForEach-Object {
        [int]($_.SamAccountName -replace "^$([regex]::Escape($BaseName))", '')
    }

if ($existing) {
    $highest = ($existing | Measure-Object -Maximum).Maximum
    Write-Verbose "Highest existing number: $highest"
}
else {
    $highest = 0
    Write-Verbose 'No existing numbered accounts found.'
}

# ── Step 6: Compute next username ────────────────────────────────────────────
$nextNumber   = $highest + 1
$newUsername   = "$BaseName$nextNumber"
$domainDNSRoot = (Get-ADDomain).DNSRoot
$upn           = "$newUsername@$domainDNSRoot"

Write-Verbose "Next username: $newUsername"
Write-Verbose "UPN: $upn"

# ── Step 7: Display summary and confirm ─────────────────────────────────────
Write-Host ''
Write-Host '╔══════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║       New AD User — Summary              ║' -ForegroundColor Cyan
Write-Host '╠══════════════════════════════════════════╣' -ForegroundColor Cyan
Write-Host "║  Username:            $newUsername"         -ForegroundColor Cyan
Write-Host "║  UPN:                 $upn"                 -ForegroundColor Cyan
Write-Host "║  Target OU:           $TargetOU"            -ForegroundColor Cyan
Write-Host "║  Group:               $GroupName"           -ForegroundColor Cyan
Write-Host "║  Enabled:             True"                 -ForegroundColor Cyan
Write-Host "║  PasswordNeverExpires: True"                -ForegroundColor Cyan
Write-Host "║  CannotChangePassword: True"                -ForegroundColor Cyan
Write-Host "║  ChangePasswordAtLogon: False"              -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

$confirm = Read-Host 'Create this account? (Y/N)'
if ($confirm -notin @('Y', 'y', 'Yes', 'yes')) {
    Write-Host 'Aborted. No changes were made.' -ForegroundColor Yellow
    return
}

# ── Step 8: Create the user ─────────────────────────────────────────────────
Write-Verbose "Creating user '$newUsername'..."
$securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force

$newUserParams = @{
    Name                  = $newUsername
    GivenName             = $newUsername
    DisplayName           = $newUsername
    SamAccountName        = $newUsername
    UserPrincipalName     = $upn
    AccountPassword       = $securePassword
    Enabled               = $true
    PasswordNeverExpires  = $true
    ChangePasswordAtLogon = $false
    Path                  = $TargetOU
}

try {
    New-ADUser @newUserParams
    Write-Verbose "User '$newUsername' created successfully."
}
catch {
    if ($_.Exception.Message -match 'already exists') {
        Write-Host "ERROR: '$newUsername' already exists — possible race condition." -ForegroundColor Red
        Write-Host 'Another admin may have just created this account. Re-run the script to get the next number.' -ForegroundColor Red
    }
    else {
        Write-Host "ERROR: Failed to create user '$newUsername'." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    throw
}

# ── Step 9: Set CannotChangePassword (post-creation) ────────────────────────
Write-Verbose "Setting CannotChangePassword on '$newUsername'..."
try {
    Set-ADUser -Identity $newUsername -CannotChangePassword $true
    Write-Verbose 'CannotChangePassword set.'
}
catch {
    Write-Host "WARNING: User created, but failed to set CannotChangePassword." -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}

# ── Step 10: Add to Domain Admins ────────────────────────────────────────────
Write-Verbose "Adding '$newUsername' to '$GroupName'..."
try {
    Add-ADGroupMember -Identity $GroupName -Members $newUsername
    Write-Verbose "Added to '$GroupName'."
}
catch {
    Write-Host "WARNING: User '$newUsername' was created but could NOT be added to '$GroupName'." -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host 'Add the user to the group manually.' -ForegroundColor Yellow
}

# ── Step 11: Verify and report ───────────────────────────────────────────────
Write-Verbose 'Verifying created account...'
$created = Get-ADUser -Identity $newUsername -Properties `
    DisplayName, GivenName, SamAccountName, UserPrincipalName, `
    Enabled, PasswordNeverExpires, CannotChangePassword, MemberOf

$groups = ($created.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace '^CN=', '' }) -join ', '

Write-Host ''
Write-Host '✓ Account created successfully!' -ForegroundColor Green
Write-Host ''
Write-Host "  Name:                  $($created.Name)"                  -ForegroundColor Green
Write-Host "  SamAccountName:        $($created.SamAccountName)"        -ForegroundColor Green
Write-Host "  UPN:                   $($created.UserPrincipalName)"     -ForegroundColor Green
Write-Host "  Enabled:               $($created.Enabled)"               -ForegroundColor Green
Write-Host "  PasswordNeverExpires:  $($created.PasswordNeverExpires)"  -ForegroundColor Green
Write-Host "  CannotChangePassword:  $($created.CannotChangePassword)"  -ForegroundColor Green
Write-Host "  Member of:             $groups"                           -ForegroundColor Green
Write-Host "  OU:                    $TargetOU"                         -ForegroundColor Green
Write-Host ''
