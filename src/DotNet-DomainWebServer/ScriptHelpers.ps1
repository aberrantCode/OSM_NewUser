#Requires -Version 5.1
<#
.SYNOPSIS
    Shared console-input helper functions for OsmUserWeb installer scripts.

.DESCRIPTION
    Dot-sourced by Install-OsmUserWeb.ps1 and friends.
    Extracted here so that Pester tests can import just the helpers without
    running the full installer body.
#>

function Read-NonEmpty {
    <#
    .SYNOPSIS Prompts repeatedly until a non-whitespace value is entered. #>
    param([string]$Prompt)
    do { $v = (Read-Host $Prompt).Trim() } while ([string]::IsNullOrWhiteSpace($v))
    return $v
}

function Read-WithDefault {
    <#
    .SYNOPSIS Prompts with a bracketed default; pressing Enter accepts the default. #>
    param([string]$Prompt, [string]$Default)
    $v = (Read-Host "$Prompt [$Default]").Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}
