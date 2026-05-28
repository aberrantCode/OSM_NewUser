# Remove PwshSpectreConsole Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every `PwshSpectreConsole` use with native PowerShell console helpers, drop the installer's PSGallery module install, and keep the Pester suite green.

**Architecture:** A new dot-sourced `src/Pwsh-NewLocalUser/ConsoleUI.ps1` defines neutral-named native helpers (`Write-AppHost`, `Show-AppBanner`, `Show-AppRule`, `Read-AppText`, `Read-AppConfirm`, `Show-AppSummary`, `Invoke-AppStatus`). `New-LocalUser.ps1` dot-sources it (guarded so tests can pre-load/mock the helpers) and calls the helpers instead of Spectre cmdlets. `install.ps1` no longer installs the module; the verification table uses native `Format-Table`.

**Tech Stack:** Windows PowerShell 5.1 / PowerShell 7, Pester 5.

**Reference spec:** `docs/superpowers/specs/2026-05-28-remove-pwshspectreconsole-design.md`

---

### Task 1: Create `ConsoleUI.ps1` with unit tests

**Files:**
- Create: `src/Pwsh-NewLocalUser/ConsoleUI.ps1`
- Test: `tests/Pester/ConsoleUI.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Create `tests/Pester/ConsoleUI.Tests.ps1`:

```powershell
#Requires -Version 5.1
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\src\Pwsh-NewLocalUser\ConsoleUI.ps1')
}

Describe 'ConvertFrom-AppMarkup' {
    It 'maps grey to DarkGray and strips the tags' {
        $r = ConvertFrom-AppMarkup '[grey]hello[/]'
        $r.Text  | Should -Be 'hello'
        $r.Color | Should -Be ([System.ConsoleColor]::DarkGray)
    }
    It 'uses the outer color and strips inner tags for nested markup' {
        $r = ConvertFrom-AppMarkup '[grey]press [bold]Enter[/] now[/]'
        $r.Text  | Should -Be 'press Enter now'
        $r.Color | Should -Be ([System.ConsoleColor]::DarkGray)
    }
    It 'returns null color when there is no recognized markup' {
        $r = ConvertFrom-AppMarkup 'Password: '
        $r.Text  | Should -Be 'Password: '
        $r.Color | Should -Be $null
    }
}

Describe 'Write-AppHost' {
    It 'renders the stripped text in the mapped color' {
        Mock Write-Host {}
        Write-AppHost '[yellow]warn[/]'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq 'warn' -and $ForegroundColor -eq [System.ConsoleColor]::Yellow
        }
    }
    It 'passes -NoNewline through and uses no color for plain text' {
        Mock Write-Host {}
        Write-AppHost 'Password: ' -NoNewline
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -eq 'Password: ' -and $NoNewline -eq $true -and $null -eq $ForegroundColor
        }
    }
}

Describe 'Read-AppConfirm (default Yes)' {
    It 'returns true on blank input' {
        Mock Read-Host { '' }
        Read-AppConfirm -Message 'ok?' | Should -BeTrue
    }
    It 'returns true on y' {
        Mock Read-Host { 'y' }
        Read-AppConfirm -Message 'ok?' | Should -BeTrue
    }
    It 'returns false on n' {
        Mock Read-Host { 'n' }
        Read-AppConfirm -Message 'ok?' | Should -BeFalse
    }
}

Describe 'Read-AppText' {
    It 'returns the default on blank input' {
        Mock Read-Host { '' }
        Read-AppText -Message 'Username' -DefaultAnswer 'erik2' | Should -Be 'erik2'
    }
    It 'returns the entered value when provided' {
        Mock Read-Host { 'custom' }
        Read-AppText -Message 'Username' -DefaultAnswer 'erik2' | Should -Be 'custom'
    }
}

Describe 'Show-AppSummary' {
    It 'prints the header and indents each data line' {
        Mock Write-Host {}
        Show-AppSummary -Header 'Summary' -Data "a : 1`nb : 2"
        Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Summary' }
        Should -Invoke Write-Host -ParameterFilter { $Object -eq '  a : 1' }
        Should -Invoke Write-Host -ParameterFilter { $Object -eq '  b : 2' }
    }
}

Describe 'Invoke-AppStatus' {
    It 'runs the scriptblock' {
        Mock Write-Host {}
        $script:ran = $false
        Invoke-AppStatus -Title 'working' -ScriptBlock { $script:ran = $true }
        $script:ran | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Invoke-Pester -Path ./tests/Pester/ConsoleUI.Tests.ps1 -Output Detailed`
Expected: FAIL — `ConvertFrom-AppMarkup`/`Write-AppHost`/etc. not recognized (ConsoleUI.ps1 does not exist yet).

- [ ] **Step 3: Implement `ConsoleUI.ps1`**

Create `src/Pwsh-NewLocalUser/ConsoleUI.ps1`:

```powershell
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path ./tests/Pester/ConsoleUI.Tests.ps1 -Output Detailed`
Expected: PASS (all describes green).

- [ ] **Step 5: Commit**

```bash
git add src/Pwsh-NewLocalUser/ConsoleUI.ps1 tests/Pester/ConsoleUI.Tests.ps1
git commit -m "feat(console-ui): add native ConsoleUI helpers to replace PwshSpectreConsole"
```

---

### Task 2: Switch `New-LocalUser.ps1` to the native helpers

**Files:**
- Modify: `src/Pwsh-NewLocalUser/New-LocalUser.ps1`
- Modify (tests first): `tests/Pester/New-LocalUser.Tests.ps1`

- [ ] **Step 1: Update the test harness to load/mock the native helpers**

In `tests/Pester/New-LocalUser.Tests.ps1`, replace the BeforeAll Spectre load block (lines 48-51):

```powershell
    # ── Load PwshSpectreConsole so Spectre cmdlets exist for mocking ──────────
    $OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $env:IgnoreSpectreEncoding = $true
    Import-Module PwshSpectreConsole -ErrorAction Stop
```

with:

```powershell
    # ── Load native ConsoleUI helpers so they exist for mocking ───────────────
    $OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    . (Join-Path $PSScriptRoot '..\..\src\Pwsh-NewLocalUser\ConsoleUI.ps1')
```

Remove the now-unnecessary `Mock Import-Module { }` line (currently line 102).

Replace the Spectre output/spinner/prompt mock block (currently lines 105-126) with:

```powershell
        # Native UI output — suppress all display
        Mock Show-AppBanner { }
        Mock Show-AppRule   { }
        Mock Write-AppHost  { }
        Mock Show-AppSummary { }

        # Status wrapper — must actually run its scriptblock
        Mock Invoke-AppStatus {
            param($Title, $ScriptBlock)
            & $ScriptBlock
        }

        # Prompts — return the expected username for Phase 3 validation
        Mock Read-AppText { $global:mockExpectedUsername }
        Mock Read-AppConfirm {
            param($Message)
            if ($Message -match 'Log on')  { return $global:mockConfirmLogon }
            if ($Message -match 'Save')    { return $global:mockConfirmSaveEnv }
            if ($Message -match 'Migrate') { return $global:mockConfirmMigrate }
            return $global:mockConfirmCreate
        }
```

Rename the remaining command references throughout the file (these appear in `Should -Invoke` assertions and the Describe title / doc comment):

- `Write-SpectreHost` → `Write-AppHost` (assertions at lines 251, 287, 330, 662)
- `Read-SpectreText` → `Read-AppText` (Describe title line 343, mock line 349, assertion line 376)
- `Read-SpectreConfirm` → `Read-AppConfirm` (assertion line 711)

Do this with explicit replace-all for each name, e.g.:
- Replace all `Write-SpectreHost` with `Write-AppHost`
- Replace all `Read-SpectreText` with `Read-AppText`
- Replace all `Read-SpectreConfirm` with `Read-AppConfirm`
- Replace all `Write-SpectreFigletText` with `Show-AppBanner`
- Replace all `Write-SpectreRule` with `Show-AppRule`
- Replace all `Format-SpectrePanel` with `Show-AppSummary`
- Replace all `Invoke-SpectreCommandWithStatus` with `Invoke-AppStatus`

Update the prose in the BeforeAll header comment (lines 7-22, 36) that names `PwshSpectreConsole` / Spectre cmdlets to the native equivalents (text-only; not asserted). Confirm no `Spectre` substring remains except in this prose if you choose to keep historical notes — the verification task greps for zero matches, so update all of them.

- [ ] **Step 2: Run the suite to verify it fails against the un-migrated script**

Run: `Invoke-Pester -Path ./tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed`
Expected: FAIL — the SUT still calls `Write-SpectreHost`/etc., so `Should -Invoke Write-AppHost` assertions are not satisfied (and/or the SUT errors importing/using Spectre that is no longer mocked).

- [ ] **Step 3: Migrate `New-LocalUser.ps1` to the helpers**

Edit `src/Pwsh-NewLocalUser/New-LocalUser.ps1`:

(a) Replace the Spectre console section (lines 37-40):

```powershell
# ── Spectre Console ───────────────────────────────────────────────────────────
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:IgnoreSpectreEncoding = $true   # we set UTF-8 above; suppress the module warning
Import-Module PwshSpectreConsole -ErrorAction Stop
```

with:

```powershell
# ── Console UI ──────────────────────────────────────────────────────────────
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
# Guarded so the Pester suite can pre-load and mock these helpers.
if (-not (Get-Command Write-AppHost -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ConsoleUI.ps1')
}
```

(b) Update the `.NOTES` Requires line (line 19):

```
    Requires: PowerShell 5.1+, admin elevation, PwshSpectreConsole module.
```

to:

```
    Requires: PowerShell 5.1+, admin elevation.
```

(c) Rename all call sites (replace-all per command name):
- `Write-SpectreHost` → `Write-AppHost`
- `Write-SpectreFigletText` → `Show-AppBanner`
- `Write-SpectreRule` → `Show-AppRule`
- `Read-SpectreText` → `Read-AppText`
- `Read-SpectreConfirm` → `Read-AppConfirm`
- `Format-SpectrePanel` → `Show-AppSummary`
- `Invoke-SpectreCommandWithStatus` → `Invoke-AppStatus`

(d) Remove the `-Spinner Dots` argument from the (now) `Invoke-AppStatus` call. Change the line (currently 273):

```powershell
} -Spinner Dots
```

to:

```powershell
}
```

(e) Replace the verification table call (currently line 296):

```powershell
} | Format-SpectreTable
```

with:

```powershell
} | Format-Table -AutoSize
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `Invoke-Pester -Path ./tests/Pester/New-LocalUser.Tests.ps1 -Output Detailed`
Expected: PASS — same test count as before the change (49 tests), all green.

- [ ] **Step 5: Commit**

```bash
git add src/Pwsh-NewLocalUser/New-LocalUser.ps1 tests/Pester/New-LocalUser.Tests.ps1
git commit -m "refactor(new-localuser): use native ConsoleUI helpers instead of PwshSpectreConsole"
```

---

### Task 3: Remove the installer's module install

**Files:**
- Modify: `install.ps1`

- [ ] **Step 1: Delete Step 8 (PwshSpectreConsole install)**

Remove this block from `install.ps1` (lines 191-197):

```powershell
# ── Step 8: Install PwshSpectreConsole if missing ────────────────────────────
$spectreInstalled = Get-Module PwshSpectreConsole -ListAvailable
if (-not $spectreInstalled) {
    Write-Host 'Installing PwshSpectreConsole module...' -ForegroundColor Cyan
    Install-Module PwshSpectreConsole -RequiredVersion 2.3.0 -Scope AllUsers -Force
    Write-Host 'PwshSpectreConsole installed.' -ForegroundColor Green
}

```

- [ ] **Step 2: Renumber the next step comment**

Change (currently line 199):

```powershell
# ── Step 9: Prompt to run ─────────────────────────────────────────────────────
```

to:

```powershell
# ── Step 8: Prompt to run ─────────────────────────────────────────────────────
```

- [ ] **Step 3: Verify no Spectre reference remains in the installer**

Run: `Select-String -Path ./install.ps1 -Pattern 'Spectre'`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add install.ps1
git commit -m "chore(install): drop PwshSpectreConsole PSGallery install (no longer needed)"
```

---

### Task 4: Update documentation

**Files:**
- Modify: `docs/NEW-LOCALUSER.md`

- [ ] **Step 1: Update prerequisites and remove the install section**

In `docs/NEW-LOCALUSER.md`:

Remove the requirement line (line 9):
```
- **PwshSpectreConsole module v2.3.0+** — provides the interactive UI
```

Remove the "Installing PwshSpectreConsole" subsection (lines 12-16: the `### Installing PwshSpectreConsole` heading and its fenced `Install-Module` block).

- [ ] **Step 2: Update flow/error/UI references**

Replace cmdlet names in the flow descriptions (lines 95, 97, 99, 101, 105):
- `Read-SpectreText` → `Read-AppText`
- `Format-SpectrePanel` → `Show-AppSummary`
- `Read-SpectreConfirm` → `Read-AppConfirm`
- `Invoke-SpectreCommandWithStatus` (spinner) → `Invoke-AppStatus` (status line)
- `Format-SpectreTable` → `Format-Table`

In the error-conditions table: delete the row `| PwshSpectreConsole not installed | Import-Module throws; script terminates |` (line 136), and replace `Spectre message` with `message` in the rows at lines 137-140.

Rename the `## Spectre Console UI` section (line 145) to `## Console UI`, update its intro (line 147) to "The script uses native ConsoleUI helpers for all interactive output:", and rewrite the table (lines 149-158) to:

```markdown
| Element | Purpose |
|---|---|
| `Show-AppBanner` | "New Local User" banner at startup |
| `Show-AppRule` | Section dividers (Password, Username, Confirm, Verification) |
| `Write-AppHost` | Styled status and error messages |
| `Read-AppText` | Username prompt with pre-filled default answer |
| `Read-AppConfirm` | Yes/No prompts for confirmation and auto-logon offer |
| `Show-AppSummary` | Confirmation summary before account creation |
| `Invoke-AppStatus` | Status line during account creation |
| `Format-Table` | Post-creation verification table |
```

Replace the encoding note (line 160) with: "UTF-8 encoding is set explicitly on startup; the helpers are dot-sourced from `ConsoleUI.ps1`."

- [ ] **Step 3: Add a changelog entry**

Under the changelog section (after the `### 2026-03-03 — Initial release` block near line 230), add:

```markdown
### 2026-05-28 — Remove PwshSpectreConsole

- Replaced all PwshSpectreConsole UI with native ConsoleUI helpers (no external module).
- Installer no longer installs PwshSpectreConsole from the PowerShell Gallery.
```

- [ ] **Step 4: Verify no Spectre reference remains in this doc**

Run: `Select-String -Path ./docs/NEW-LOCALUSER.md -Pattern 'Spectre'`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add docs/NEW-LOCALUSER.md
git commit -m "docs(new-localuser): document native ConsoleUI, drop PwshSpectreConsole"
```

---

### Task 5: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full Pester directory**

Run: `Invoke-Pester -Path ./tests/Pester -Output Detailed`
Expected: `New-LocalUser.Tests.ps1` and `ConsoleUI.Tests.ps1` all pass; no new failures introduced in other suites versus baseline.

- [ ] **Step 2: Prove zero Spectre references remain in code**

Run:
```powershell
Get-ChildItem -Recurse -Include *.ps1 -Path .\src,.\scripts,.\tests |
  Select-String -Pattern 'Spectre'
Select-String -Path .\install.ps1,.\docs\NEW-LOCALUSER.md -Pattern 'Spectre'
```
Expected: no output. (Historical `docs/plans/*.md` are intentionally left unchanged.)

- [ ] **Step 3: Prove no runtime module dependency (PowerShell 7)**

Run (elevated):
```powershell
pwsh -NoProfile -NonInteractive -File .\src\Pwsh-NewLocalUser\New-LocalUser.ps1 *> $env:TEMP\nlu-pwsh7.log; Get-Content $env:TEMP\nlu-pwsh7.log
```
Expected: prints the "New Local User" banner and "--- Password ---" rule, then stops at the `Read-Host` password prompt with a NonInteractive error. No `Import-Module PwshSpectreConsole` / module-not-found error. No account created.

- [ ] **Step 4: Prove no runtime module dependency (Windows PowerShell 5.1)**

Run (elevated):
```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\src\Pwsh-NewLocalUser\New-LocalUser.ps1 *> $env:TEMP\nlu-ps51.log; Get-Content $env:TEMP\nlu-ps51.log
```
Expected: same as Step 3 — banner + Password rule, then the NonInteractive `Read-Host` stop, no module dependency.

---

## Notes for the implementer

- The dot-source guard (`if (-not (Get-Command Write-AppHost ...))`) is essential: it lets the Pester suite pre-load `ConsoleUI.ps1` and register mocks that the SUT then uses, instead of the SUT re-defining the real helpers over the mocks.
- Confirm prompts default to **Yes** on purpose — this matches the old `Read-SpectreConfirm` default (`DefaultAnswer = "y"`).
- Do not uninstall `PwshSpectreConsole` from machines; it simply becomes unused.
