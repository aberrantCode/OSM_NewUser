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

function ConvertTo-SafeNameComponent {
    param([string]$Value)

    $normalized = if ([string]::IsNullOrWhiteSpace($Value)) { 'Migrated File' } else { $Value }
    $knownNames = @{
        'ManyCam' = 'ManyCam'
        'ShareX' = 'ShareX'
        'ScreenRecordings' = 'Screen Recordings'
    }
    if ($knownNames.ContainsKey($normalized)) {
        $normalized = $knownNames[$normalized]
    }
    $normalized = $normalized -replace '[_\.\-]+', ' '
    $normalized = $normalized -replace '\s+', ' '
    $normalized = $normalized.Trim()

    foreach ($invalid in [IO.Path]::GetInvalidFileNameChars()) {
        $normalized = $normalized.Replace([string]$invalid, '')
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return 'Migrated File'
    }

    return $normalized
}

function Remove-DateTokensFromFileName {
    param([string]$BaseName)

    $cleaned = $BaseName
    $datePatterns = @(
        '(?<!\d)(?:19|20)\d{2}[._ -]?(?:0[1-9]|1[0-2])[._ -]?(?:0[1-9]|[12]\d|3[01])(?!\d)',
        '(?<!\d)(?:0[1-9]|1[0-2])[._ -]?(?:0[1-9]|[12]\d|3[01])[._ -]?(?:19|20)\d{2}(?!\d)',
        '(?<!\d)(?:19|20)\d{2}[._ -]?(?:0[1-9]|1[0-2])(?!\d)',
        '(?<!\d)(?:19|20)\d{2}(?!\d)'
    )

    foreach ($pattern in $datePatterns) {
        $cleaned = [regex]::Replace($cleaned, $pattern, ' ')
    }

    return ConvertTo-SafeNameComponent -Value $cleaned
}

function ConvertTo-SourceNameComponent {
    param([string]$RelativeDirectory)

    $shellFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music') | ForEach-Object { [void]$shellFolders.Add($_) }

    $parts = @($RelativeDirectory -split '[\\/]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $meaningful = New-Object System.Collections.Generic.List[string]

    foreach ($part in $parts) {
        if ($shellFolders.Contains($part)) { continue }
        if ($part -like 'OneDrive*') { continue }
        if ($part -match '^(?:19|20)\d{2}(?:[-_\.](?:0[1-9]|1[0-2]))?(?:[-_\.](?:0[1-9]|[12]\d|3[01]))?$') { continue }
        $meaningful.Add((ConvertTo-SafeNameComponent -Value $part)) | Out-Null
    }

    if ($meaningful.Count -eq 0 -and $parts.Count -gt 0) {
        return ConvertTo-SafeNameComponent -Value $parts[0]
    }

    if ($meaningful.Count -gt 2) {
        return (($meaningful | Select-Object -First 2) -join ' - ')
    }

    return ($meaningful -join ' - ')
}

function Get-FileCreatedDateToken {
    param([object]$File)

    $created = $null
    if ($File.PSObject.Properties.Name -contains 'CreationTime' -and $null -ne $File.CreationTime) {
        $created = $File.CreationTime
    } elseif ($File.PSObject.Properties.Name -contains 'CreationTimeUtc' -and $null -ne $File.CreationTimeUtc) {
        $created = $File.CreationTimeUtc.ToLocalTime()
    } elseif ($File.PSObject.Properties.Name -contains 'LastWriteTime' -and $null -ne $File.LastWriteTime) {
        $created = $File.LastWriteTime
    } else {
        $created = Get-Date
    }

    return ([datetime]$created).ToString('yyyy-MM-dd')
}

function Get-UniqueMigrationDestination {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationDirectory,
        [Parameter(Mandatory)]
        [string]$FileNameWithoutDate,
        [Parameter(Mandatory)]
        [string]$DateToken,
        [Parameter(Mandatory)]
        [string]$Extension
    )

    $candidate = Join-Path $DestinationDirectory ("{0} - {1}{2}" -f $FileNameWithoutDate, $DateToken, $Extension)
    if (-not (Test-Path $candidate -PathType Leaf)) {
        return $candidate
    }

    $counter = 1
    do {
        $candidate = Join-Path $DestinationDirectory ("{0} - {1} {2}{3}" -f $FileNameWithoutDate, $DateToken, $counter, $Extension)
        $counter++
    } while (Test-Path $candidate -PathType Leaf)

    return $candidate
}

function ConvertTo-CsvField {
    param([string]$Value)

    $safeValue = if ($null -eq $Value) { '' } else { $Value }
    return '"' + ($safeValue -replace '"', '""') + '"'
}

function Add-MigrationLedgerRow {
    param(
        [Parameter(Mandatory)]
        [string]$LedgerPath,
        [Parameter(Mandatory)]
        [string]$SourceFilePath,
        [Parameter(Mandatory)]
        [string]$DestinationFilePath
    )

    $ledgerDirectory = Split-Path -Path $LedgerPath -Parent
    if (-not (Test-Path $ledgerDirectory -PathType Container)) {
        $null = New-Item -Path $ledgerDirectory -ItemType Directory -Force
    }

    if (-not (Test-Path $LedgerPath -PathType Leaf)) {
        Add-Content -Path $LedgerPath -Value 'SourceFilePath,DestinationFilePath,DateMoved'
    }

    $row = @(
        ConvertTo-CsvField -Value $SourceFilePath
        ConvertTo-CsvField -Value $DestinationFilePath
        ConvertTo-CsvField -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    ) -join ','

    Add-Content -Path $LedgerPath -Value $row
}

function Initialize-MigrationLedger {
    param(
        [Parameter(Mandatory)]
        [string]$OldProfilePath,
        [Parameter(Mandatory)]
        [string]$NewProfilePath,
        [Parameter(Mandatory)]
        [string]$RelativeLedgerPath
    )

    $oldLedgerPath = Join-Path $OldProfilePath $RelativeLedgerPath
    $newLedgerPath = Join-Path $NewProfilePath $RelativeLedgerPath
    $newLedgerDirectory = Split-Path -Path $newLedgerPath -Parent

    if (-not (Test-Path $newLedgerDirectory -PathType Container)) {
        $null = New-Item -Path $newLedgerDirectory -ItemType Directory -Force
    }

    if ((Test-Path $oldLedgerPath -PathType Leaf) -and -not (Test-Path $newLedgerPath -PathType Leaf)) {
        if ($PSCmdlet.ShouldProcess($newLedgerPath, "Copy migration ledger '$oldLedgerPath'")) {
            Copy-Item -Path $oldLedgerPath -Destination $newLedgerPath -Force
        }
    }

    if (-not (Test-Path $newLedgerPath -PathType Leaf)) {
        Add-Content -Path $newLedgerPath -Value 'SourceFilePath,DestinationFilePath,DateMoved'
    }

    return $newLedgerPath
}

$resolvedOldProfile = if ($PreviousUserProfilePath) { $PreviousUserProfilePath } else { Join-Path 'C:\Users' $PreviousUserName }
$resolvedNewProfile = if ($NewUserProfilePath) { $NewUserProfilePath } else { Join-Path 'C:\Users' $NewUserName }

Write-MigrationLog -Message "Starting profile migration from '$resolvedOldProfile' to '$resolvedNewProfile'."
Write-MigrationLog -Message "Using config '$ConfigPath'."

$migrationLedgerRelativePath = 'Documents\OSM_ProfileMigrationLog.csv'
$migrationLedgerPath = Initialize-MigrationLedger -OldProfilePath $resolvedOldProfile -NewProfilePath $resolvedNewProfile -RelativeLedgerPath $migrationLedgerRelativePath

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
    $matched = @(Get-ChildItem @getChildItemArgs)

    if ($matched.Count -eq 0) {
        continue
    }

    Write-MigrationLog -Message ("Rule '{0}\{1}' matched {2} file(s)." -f $rule.RelativePath, $rule.Pattern, $matched.Count)

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

    foreach ($file in $matched) {
        $relativeFilePath = $file.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
        $sourceProfileRelativePath = $file.FullName.Substring($resolvedOldProfile.Length).TrimStart('\', '/')
        $sourceProfileRelativeDirectory = Split-Path -Path $sourceProfileRelativePath -Parent
        $relativeDirectoryUnderRule = Split-Path -Path $relativeFilePath -Parent
        $destinationRoot = Join-Path $resolvedNewProfile $rule.RelativePath
        $destinationDirectory = if ([string]::IsNullOrWhiteSpace($relativeDirectoryUnderRule)) {
            $destinationRoot
        } else {
            Join-Path $destinationRoot $relativeDirectoryUnderRule
        }
        if (-not (Test-Path $destinationDirectory -PathType Container)) {
            $null = New-Item -Path $destinationDirectory -ItemType Directory -Force
        }

        $sourceNameComponent = ConvertTo-SourceNameComponent -RelativeDirectory $sourceProfileRelativeDirectory
        $originalNameComponent = Remove-DateTokensFromFileName -BaseName $file.BaseName
        $dateToken = Get-FileCreatedDateToken -File $file
        $fileNameWithoutDate = (@(
            ConvertTo-SafeNameComponent -Value $PreviousUserName
            $sourceNameComponent
            $originalNameComponent
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' - '
        $destinationFile = Get-UniqueMigrationDestination -DestinationDirectory $destinationDirectory -FileNameWithoutDate $fileNameWithoutDate -DateToken $dateToken -Extension $file.Extension

        try {
            if ($PSCmdlet.ShouldProcess($destinationFile, "Copy '$($file.FullName)'")) {
                Copy-Item -Path $file.FullName -Destination $destinationFile -Force
                Add-MigrationLedgerRow -LedgerPath $migrationLedgerPath -SourceFilePath $file.FullName -DestinationFilePath $destinationFile
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
