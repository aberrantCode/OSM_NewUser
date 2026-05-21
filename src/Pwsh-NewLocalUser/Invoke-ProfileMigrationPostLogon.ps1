#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PreviousUserName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NewUserName,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'ProfileMigrationPatterns.json'),
    [string]$PreviousUserProfilePath,
    [string]$NewUserProfilePath,
    [string]$LogPath,
    [switch]$SkipRemovalPrompt,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

function Test-IsElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    $safeValue = if ($null -eq $Value) { '' } else { $Value }
    return '"' + ($safeValue -replace '"', '\"') + '"'
}

if (-not (Test-IsElevated)) {
    $elevationArgs = @(
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        ('-File ' + (ConvertTo-ProcessArgument -Value $PSCommandPath))
        ('-PreviousUserName ' + (ConvertTo-ProcessArgument -Value $PreviousUserName))
        ('-NewUserName ' + (ConvertTo-ProcessArgument -Value $NewUserName))
        ('-ConfigPath ' + (ConvertTo-ProcessArgument -Value $ConfigPath))
    )
    if ($PreviousUserProfilePath) { $elevationArgs += ('-PreviousUserProfilePath ' + (ConvertTo-ProcessArgument -Value $PreviousUserProfilePath)) }
    if ($NewUserProfilePath) { $elevationArgs += ('-NewUserProfilePath ' + (ConvertTo-ProcessArgument -Value $NewUserProfilePath)) }
    if ($LogPath) { $elevationArgs += ('-LogPath ' + (ConvertTo-ProcessArgument -Value $LogPath)) }
    if ($SkipRemovalPrompt) { $elevationArgs += '-SkipRemovalPrompt' }
    if ($NonInteractive) { $elevationArgs += '-NonInteractive' }
    if ($WhatIfPreference) { $elevationArgs += '-WhatIf' }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($elevationArgs -join ' ')
    return
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDirectory = Join-Path $env:ProgramData 'OSM\logs'
    if (-not (Test-Path $logDirectory -PathType Container)) {
        $null = New-Item -Path $logDirectory -ItemType Directory -Force
    }
    $LogPath = Join-Path $logDirectory ("profile-migration-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Write-MigrationLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $line

    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Get-MigrationRules {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) {
        Write-MigrationLog -Level 'WARN' -Message "Migration config not found at '$Path'."
        return @()
    }

    $raw = Get-Content -Path $Path -ErrorAction Stop | Out-String
    $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    return @($parsed) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.RelativePath) -and
        -not [string]::IsNullOrWhiteSpace($_.Pattern)
    }
}

$resolvedOldProfile = if ($PreviousUserProfilePath) { $PreviousUserProfilePath } else { Join-Path 'C:\Users' $PreviousUserName }
$resolvedNewProfile = if ($NewUserProfilePath) { $NewUserProfilePath } else { Join-Path 'C:\Users' $NewUserName }

Write-MigrationLog -Message "Starting profile migration from '$resolvedOldProfile' to '$resolvedNewProfile'."
Write-MigrationLog -Message "Using config '$ConfigPath'."

$copiedCount = 0
$failedCount = 0
$rules = Get-MigrationRules -Path $ConfigPath
$newUserPrincipal = "$env:COMPUTERNAME\$NewUserName"

foreach ($rule in $rules) {
    $sourcePath = Join-Path $resolvedOldProfile $rule.RelativePath
    if (-not (Test-Path $sourcePath -PathType Container)) {
        continue
    }

    $getChildItemArgs = @{
        Path        = $sourcePath
        Filter      = $rule.Pattern
        File        = $true
        ErrorAction = 'SilentlyContinue'
    }
    if ($rule.Recurse) { $getChildItemArgs.Recurse = $true }
    $matches = @(Get-ChildItem @getChildItemArgs)

    if ($matches.Count -eq 0) {
        continue
    }

    Write-MigrationLog -Message ("Rule '{0}\{1}' matched {2} file(s)." -f $rule.RelativePath, $rule.Pattern, $matches.Count)

    try {
        if ($PSCmdlet.ShouldProcess($sourcePath, "Grant modify access for $newUserPrincipal")) {
            $grantArgs = @($sourcePath, '/grant', "${newUserPrincipal}:(OI)(CI)M", '/T', '/C')
            $grantProcess = Start-Process -FilePath 'icacls.exe' -ArgumentList $grantArgs -PassThru -Wait -NoNewWindow
            if ($grantProcess.ExitCode -ne 0) {
                Write-MigrationLog -Level 'WARN' -Message "icacls exited with code $($grantProcess.ExitCode) for '$sourcePath'."
            }
        }
    } catch {
        Write-MigrationLog -Level 'WARN' -Message "Failed to grant ACLs for '$sourcePath': $($_.Exception.Message)"
    }

    foreach ($file in $matches) {
        $relativeFilePath = $file.FullName.Substring($sourcePath.Length).TrimStart('\')
        $destinationRoot = Join-Path $resolvedNewProfile $rule.RelativePath
        $destinationFile = Join-Path $destinationRoot $relativeFilePath
        $destinationDirectory = Split-Path -Path $destinationFile -Parent
        if (-not (Test-Path $destinationDirectory -PathType Container)) {
            $null = New-Item -Path $destinationDirectory -ItemType Directory -Force
        }

        try {
            if ($PSCmdlet.ShouldProcess($destinationFile, "Copy '$($file.FullName)'")) {
                Copy-Item -Path $file.FullName -Destination $destinationFile -Force
            }
            $copiedCount++
        } catch {
            $failedCount++
            Write-MigrationLog -Level 'WARN' -Message "Failed to copy '$($file.FullName)' to '$destinationFile': $($_.Exception.Message)"
        }
    }
}

$summary = "Migration complete. Copied: $copiedCount. Failed: $failedCount. Log: $LogPath"
Write-MigrationLog -Message $summary
Write-Host $summary -ForegroundColor Green

if (-not $SkipRemovalPrompt -and -not $NonInteractive -and $PreviousUserName -ne $NewUserName) {
    $removeResponse = Read-Host "Remove previous local user '$PreviousUserName' from this workstation? (Y/N)"
    if ($removeResponse -match '^(?i)y(?:es)?$') {
        try {
            if ($PSCmdlet.ShouldProcess($PreviousUserName, 'Remove local user')) {
                Remove-LocalUser -Name $PreviousUserName -ErrorAction Stop
            }
            Write-MigrationLog -Message "Removed previous local user '$PreviousUserName'."
        } catch {
            Write-MigrationLog -Level 'ERROR' -Message "Failed to remove previous local user '$PreviousUserName': $($_.Exception.Message)"
            throw
        }
    } else {
        Write-MigrationLog -Message "Previous user '$PreviousUserName' was kept."
    }
}
