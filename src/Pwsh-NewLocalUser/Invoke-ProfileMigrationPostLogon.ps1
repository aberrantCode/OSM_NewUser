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

# Resolve the log path and define the logger FIRST — before the elevation
# branch — so the pre-elevation relaunch (including a denied/failed UAC prompt)
# is captured in the same file as the elevated run. With an explicit -LogPath
# both halves share one file; with the default, the non-elevated instance
# resolves the path and passes it down so the elevated child appends to it too.
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDirectory = Join-Path $env:ProgramData 'OSM\logs'
    if (-not (Test-Path $logDirectory -PathType Container)) {
        # -WhatIf:$false so the log infrastructure is always usable, even when
        # the migration itself is running under -WhatIf.
        $null = New-Item -Path $logDirectory -ItemType Directory -Force -WhatIf:$false
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

    # Logging must NEVER abort the migration. -WhatIf:$false keeps the audit
    # trail flowing even when the script as a whole runs under -WhatIf.
    try {
        Add-Content -Path $LogPath -Value $line -WhatIf:$false -ErrorAction Stop
    } catch {
        # Swallow — a failed log write is not worth failing an unattended migration.
    }

    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    try { Write-Host $line -ForegroundColor $color } catch { }
}

# Record the full invocation up front so the log is self-describing regardless
# of which branch (elevated vs. relaunch) ends up doing the work. Logged in BOTH
# the non-elevated parent and the elevated child, so the file shows both halves.
$isElevated = Test-IsElevated
$actingUser = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { '<unknown>' }

Write-MigrationLog -Message '===== Profile migration post-logon invoked ====='
Write-MigrationLog -Message ("Parameters: PreviousUserName='{0}', NewUserName='{1}', ConfigPath='{2}'." -f $PreviousUserName, $NewUserName, $ConfigPath)
Write-MigrationLog -Message ("Parameters: PreviousUserProfilePath='{0}', NewUserProfilePath='{1}', LogPath='{2}'." -f `
    $(if ($PreviousUserProfilePath) { $PreviousUserProfilePath } else { '<resolve-by-SID>' }), `
    $(if ($NewUserProfilePath) { $NewUserProfilePath } else { '<resolve-by-SID>' }), `
    $LogPath)
Write-MigrationLog -Message ("Switches: SkipRemovalPrompt={0}, NonInteractive={1}, WhatIf={2}." -f [bool]$SkipRemovalPrompt, [bool]$NonInteractive, [bool]$WhatIfPreference)
Write-MigrationLog -Message ("Context: Elevated={0}, User='{1}', Computer='{2}', PSVersion={3}." -f $isElevated, $actingUser, $env:COMPUTERNAME, $PSVersionTable.PSVersion)

if (-not $isElevated) {
    $elevationArgs = @(
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        ('-File ' + (ConvertTo-ProcessArgument -Value $PSCommandPath))
        ('-PreviousUserName ' + (ConvertTo-ProcessArgument -Value $PreviousUserName))
        ('-NewUserName ' + (ConvertTo-ProcessArgument -Value $NewUserName))
        ('-ConfigPath ' + (ConvertTo-ProcessArgument -Value $ConfigPath))
        # Always forward the resolved log path so the elevated child appends to
        # the SAME file rather than minting its own timestamped one.
        ('-LogPath ' + (ConvertTo-ProcessArgument -Value $LogPath))
    )
    if ($PreviousUserProfilePath) { $elevationArgs += ('-PreviousUserProfilePath ' + (ConvertTo-ProcessArgument -Value $PreviousUserProfilePath)) }
    if ($NewUserProfilePath) { $elevationArgs += ('-NewUserProfilePath ' + (ConvertTo-ProcessArgument -Value $NewUserProfilePath)) }
    if ($SkipRemovalPrompt) { $elevationArgs += '-SkipRemovalPrompt' }
    if ($NonInteractive) { $elevationArgs += '-NonInteractive' }
    if ($WhatIfPreference) { $elevationArgs += '-WhatIf' }

    $relaunchArguments = $elevationArgs -join ' '
    Write-MigrationLog -Message 'Process is not elevated; relaunching elevated via UAC (Start-Process -Verb RunAs).'
    Write-MigrationLog -Message ("Relaunch command: powershell.exe {0}" -f $relaunchArguments)

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunchArguments
        Write-MigrationLog -Message 'Elevated relaunch started; this non-elevated instance is exiting.'
    } catch {
        # A cancelled/denied UAC prompt throws here. Previously this died silently
        # before any log existed; now it is recorded before we re-throw.
        Write-MigrationLog -Level 'ERROR' -Message ("Failed to relaunch elevated (UAC denied or unavailable?): {0}" -f $_.Exception.Message)
        throw
    }
    return
}

function Get-UserSidByName {
    param([Parameter(Mandatory)][string]$UserName)
    try {
        $localUser = Get-LocalUser -Name $UserName -ErrorAction Stop
        return $localUser.SID.Value
    } catch {
        return $null
    }
}

function Resolve-UserProfilePath {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [string]$ExplicitPath,
        [string]$Label = 'user'
    )

    # An explicit path (e.g. handed down from New-LocalUser.ps1 for the previous
    # user) always wins.
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        Write-MigrationLog -Message ("Resolved {0} profile from explicit argument: '{1}'." -f $Label, $ExplicitPath)
        return $ExplicitPath
    }

    # The on-disk profile folder is NOT always C:\Users\<name>. When a stale
    # C:\Users\<name> from a prior OS install already squats that name in
    # ProfileList, Windows provisions the real profile at C:\Users\<name>.<DOMAIN>.
    # ProfileList keyed by the account SID is the authoritative source of truth.
    $sid = Get-UserSidByName -UserName $UserName
    if (-not [string]::IsNullOrWhiteSpace($sid)) {
        $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        try {
            $imagePath = (Get-ItemProperty -Path $profileListKey -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath
            if (-not [string]::IsNullOrWhiteSpace($imagePath)) {
                $expandedPath = [Environment]::ExpandEnvironmentVariables($imagePath)
                Write-MigrationLog -Message ("Resolved {0} profile from ProfileList (SID {1}): '{2}'." -f $Label, $sid, $expandedPath)
                return $expandedPath
            }
        } catch {
            Write-MigrationLog -Level 'WARN' -Message ("ProfileList lookup failed for {0} (SID {1}): {2}" -f $Label, $sid, $_.Exception.Message)
            # Fall through to the C:\Users\<name> default below.
        }
    } else {
        Write-MigrationLog -Level 'WARN' -Message ("Could not resolve a SID for {0} '{1}'." -f $Label, $UserName)
    }

    $fallbackPath = Join-Path 'C:\Users' $UserName
    Write-MigrationLog -Message ("Resolved {0} profile via C:\Users fallback: '{1}' (SID={2})." -f $Label, $fallbackPath, $(if ($sid) { $sid } else { '<none>' }))
    return $fallbackPath
}

function Remove-UserProfileDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$UserSid,
        [Parameter(Mandatory)][string]$ProfilePath
    )

    # Preferred path: Win32_UserProfile cleans up both the directory and the
    # HKLM\...\ProfileList\<SID> registry entry in one CIM operation. It also
    # handles the junction points / hard-linked legacy folders that a plain
    # Remove-Item -Recurse trips over.
    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        $cimProfile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$UserSid'" -ErrorAction SilentlyContinue
        if ($cimProfile) {
            if ($cimProfile.Loaded) {
                throw "Profile for SID '$UserSid' is currently loaded and cannot be removed."
            }
            if ($PSCmdlet.ShouldProcess($ProfilePath, "Remove Win32_UserProfile (registry + directory) for SID '$UserSid'")) {
                Remove-CimInstance -InputObject $cimProfile -ErrorAction Stop
            }
            return
        }
    }

    # Fallback when no Win32_UserProfile record exists (rare — usually means the
    # profile was already partially cleaned up): remove the directory ourselves
    # and best-effort remove the orphaned ProfileList registry entry.
    if (Test-Path $ProfilePath -PathType Container) {
        if ($PSCmdlet.ShouldProcess($ProfilePath, 'Remove profile directory')) {
            Remove-Item -Path $ProfilePath -Recurse -Force -ErrorAction Stop
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$UserSid"
        if (Test-Path $profileListKey) {
            if ($PSCmdlet.ShouldProcess($profileListKey, 'Remove orphaned ProfileList registry entry')) {
                Remove-Item -Path $profileListKey -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
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

    # Wrap the whole pipeline in @(): a single passing segment would otherwise be
    # unwrapped into a scalar string, so $parts[0] below would index the STRING and
    # return its first character (e.g. 'Videos' -> 'V') instead of the segment.
    $parts = @(@($RelativeDirectory -split '[\\/]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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

$resolvedOldProfile = Resolve-UserProfilePath -UserName $PreviousUserName -ExplicitPath $PreviousUserProfilePath -Label 'previous'
$resolvedNewProfile = Resolve-UserProfilePath -UserName $NewUserName -ExplicitPath $NewUserProfilePath -Label 'new'

Write-MigrationLog -Message "Starting profile migration from '$resolvedOldProfile' to '$resolvedNewProfile'."
Write-MigrationLog -Message "Using config '$ConfigPath'."

$migrationLedgerRelativePath = 'Documents\OSM_ProfileMigrationLog.csv'
$migrationLedgerPath = Initialize-MigrationLedger -OldProfilePath $resolvedOldProfile -NewProfilePath $resolvedNewProfile -RelativeLedgerPath $migrationLedgerRelativePath
Write-MigrationLog -Message ("Migration ledger: '{0}'." -f $migrationLedgerPath)

$copiedCount = 0
$failedCount = 0
$skippedCount = 0
$rules = Get-MigrationRules -Path $ConfigPath
Write-MigrationLog -Message ("Loaded {0} migration rule(s) from '{1}'." -f @($rules).Count, $ConfigPath)
$newUserPrincipal = "$env:COMPUTERNAME\$NewUserName"

foreach ($rule in $rules) {
    $ruleLabel = '{0}\{1}' -f $rule.RelativePath, $rule.Pattern
    $sourcePath = Join-Path $resolvedOldProfile $rule.RelativePath
    if (-not (Test-Path $sourcePath -PathType Container)) {
        Write-MigrationLog -Message ("Rule '{0}': source directory '{1}' not found; skipping." -f $ruleLabel, $sourcePath)
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
        Write-MigrationLog -Message ("Rule '{0}': matched 0 file(s) in '{1}'; skipping." -f $ruleLabel, $sourcePath)
        continue
    }

    Write-MigrationLog -Message ("Rule '{0}': matched {1} file(s) in '{2}'." -f $ruleLabel, $matched.Count, $sourcePath)

    try {
        if ($PSCmdlet.ShouldProcess($sourcePath, "Grant modify access for $newUserPrincipal")) {
            $grantArgs = @($sourcePath, '/grant', "${newUserPrincipal}:(OI)(CI)M", '/T', '/C')
            $grantProcess = Start-Process -FilePath 'icacls.exe' -ArgumentList $grantArgs -PassThru -Wait -NoNewWindow
            $grantLevel = if ($grantProcess.ExitCode -eq 0) { 'INFO' } else { 'WARN' }
            Write-MigrationLog -Level $grantLevel -Message ("icacls grant for '{0}' exited with code {1}." -f $sourcePath, $grantProcess.ExitCode)
        } else {
            Write-MigrationLog -Message ("WhatIf: would grant modify access for {0} on '{1}'." -f $newUserPrincipal, $sourcePath)
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
                $copiedCount++
                Write-MigrationLog -Message ("Copied '{0}' -> '{1}'." -f $file.FullName, $destinationFile)
            } else {
                # ShouldProcess returned $false (e.g. running under -WhatIf): record
                # the intended action without performing it, and don't count it as copied.
                $skippedCount++
                Write-MigrationLog -Message ("WhatIf: would copy '{0}' -> '{1}'." -f $file.FullName, $destinationFile)
            }
        } catch {
            $failedCount++
            Write-MigrationLog -Level 'WARN' -Message "Failed to copy '$($file.FullName)' to '$destinationFile': $($_.Exception.Message)"
        }
    }
}

$summary = "Migration complete. Copied: $copiedCount. Skipped (WhatIf): $skippedCount. Failed: $failedCount. Log: $LogPath"
Write-MigrationLog -Message $summary
Write-Host $summary -ForegroundColor Green

# Log WHY removal does/doesn't happen so the absence of a removal is never
# ambiguous in the audit trail.
if ($SkipRemovalPrompt) {
    Write-MigrationLog -Message 'Skipping previous-user removal (SkipRemovalPrompt set).'
} elseif ($NonInteractive) {
    Write-MigrationLog -Message 'Skipping previous-user removal (NonInteractive set; no console to prompt on).'
} elseif ($PreviousUserName -eq $NewUserName) {
    Write-MigrationLog -Message 'Skipping previous-user removal (previous and new user names are identical).'
} else {
    $removeResponse = Read-Host "Remove previous local user '$PreviousUserName' from this workstation? (Y/N)"
    if ($removeResponse -match '^(?i)y(?:es)?$') {
        # Capture SID *before* Remove-LocalUser so we can later look up the
        # Win32_UserProfile by SID. After the account is gone Get-LocalUser
        # can no longer resolve the name.
        $previousUserSid = Get-UserSidByName -UserName $PreviousUserName
        Write-MigrationLog -Message ("User chose to remove previous user '{0}'. Captured SID before removal: {1}." -f $PreviousUserName, $(if ($previousUserSid) { $previousUserSid } else { '<none>' }))

        try {
            if ($PSCmdlet.ShouldProcess($PreviousUserName, 'Remove local user')) {
                Remove-LocalUser -Name $PreviousUserName -ErrorAction Stop
            }
            Write-MigrationLog -Message "Removed previous local user '$PreviousUserName'."
        } catch {
            Write-MigrationLog -Level 'ERROR' -Message "Failed to remove previous local user '$PreviousUserName': $($_.Exception.Message)"
            throw
        }

        # Offer to also remove the profile directory + ProfileList registry
        # entry. Without this, the now-orphaned C:\Users\<old> remains on
        # disk and the SID stays in HKLM\...\ProfileList.
        $profileDirExists      = Test-Path $resolvedOldProfile -PathType Container
        $hasProfileListEntry   = (-not [string]::IsNullOrWhiteSpace($previousUserSid)) -and `
                                 (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$previousUserSid")
        Write-MigrationLog -Message ("Profile cleanup check: directory exists={0}, ProfileList entry present={1}." -f $profileDirExists, $hasProfileListEntry)
        if ($profileDirExists -or $hasProfileListEntry) {
            $removeDirResponse = Read-Host "Also remove the previous user's profile directory '$resolvedOldProfile' (and registry entries)? (Y/N)"
            if ($removeDirResponse -match '^(?i)y(?:es)?$') {
                try {
                    Remove-UserProfileDirectory -UserSid $previousUserSid -ProfilePath $resolvedOldProfile
                    Write-MigrationLog -Message "Removed profile directory '$resolvedOldProfile' for previous user '$PreviousUserName'."
                } catch {
                    Write-MigrationLog -Level 'WARN' -Message "Failed to remove profile directory '$resolvedOldProfile': $($_.Exception.Message)"
                }
            } else {
                Write-MigrationLog -Message "Profile directory '$resolvedOldProfile' was kept (user declined)."
            }
        }
    } else {
        Write-MigrationLog -Message "Previous user '$PreviousUserName' was kept (user declined removal)."
    }
}
