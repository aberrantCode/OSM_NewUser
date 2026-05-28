#Requires -Version 5.1
<#
.SYNOPSIS
    Native console UI helpers for New-LocalUser.ps1 (no external module).
.DESCRIPTION
    Replaces PwshSpectreConsole. Renders ASCII + Write-Host colors only, so
    output is correct on legacy Windows PowerShell 5.1 consoles.
#>

$script:AppColorMap = @{
    grey   = [System.ConsoleColor]::DarkGray
    yellow = [System.ConsoleColor]::Yellow
    red    = [System.ConsoleColor]::Red
    green  = [System.ConsoleColor]::Green
    cyan   = [System.ConsoleColor]::Cyan
}

function ConvertFrom-AppMarkup {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    $color = $null
    foreach ($m in [regex]::Matches($Message, '\[(\w+)\]')) {
        $tag = $m.Groups[1].Value.ToLower()
        if ($script:AppColorMap.ContainsKey($tag)) { $color = $script:AppColorMap[$tag]; break }
    }
    $text = [regex]::Replace($Message, '\[/?[^\]]*\]', '')
    return [PSCustomObject]@{ Text = $text; Color = $color }
}

function Write-AppHost {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [switch]$NoNewline
    )
    $parsed = ConvertFrom-AppMarkup -Message $Message
    $params = @{ Object = $parsed.Text; NoNewline = $NoNewline }
    if ($null -ne $parsed.Color) { $params.ForegroundColor = $parsed.Color }
    Write-Host @params
}

function Show-AppBanner {
    param([Parameter(Mandatory)][string]$Text)
    $bar = '=' * 15
    Write-Host ''
    Write-Host "$bar  $Text  $bar" -ForegroundColor Cyan
    Write-Host ''
}

function Show-AppRule {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host "--- $Title ---" -ForegroundColor Cyan
}

function Show-AppSummary {
    param(
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Data
    )
    Write-Host $Header
    foreach ($line in ($Data -split "`n")) {
        Write-Host ('  ' + $line.TrimEnd("`r"))
    }
}

function Read-AppText {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$DefaultAnswer = ''
    )
    $prompt = if ([string]::IsNullOrEmpty($DefaultAnswer)) { $Message } else { "$Message [$DefaultAnswer]" }
    $answer = Read-Host -Prompt $prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultAnswer }
    return $answer
}

function Read-AppConfirm {
    param([Parameter(Mandatory)][string]$Message)
    while ($true) {
        $answer = Read-Host -Prompt "$Message [Y/n]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $true }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Write-Host 'Please answer Y or N.' -ForegroundColor Yellow
    }
}

function Invoke-AppStatus {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Write-Host $Title -ForegroundColor Cyan
    & $ScriptBlock
}
