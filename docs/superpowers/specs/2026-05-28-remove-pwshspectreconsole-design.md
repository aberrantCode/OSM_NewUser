# Remove PwshSpectreConsole — Design

**Date:** 2026-05-28
**Status:** Approved (pending spec review)

## Motivation

`New-LocalUser.ps1` depends on the third-party `PwshSpectreConsole` module for all
its console UI (banner, section rules, colored messages, prompts, summary panel,
status spinner, verification table). This dependency has two costs:

1. **Install fragility on stock machines.** `install.ps1` Step 8 installs the module
   from the PowerShell Gallery. On a stock Windows PowerShell 5.1 box with an
   unconfigured PSGallery/NuGet provider this fails (observed: *"Source Location …
   is not valid / failed to download"*), which aborts the self-update mid-way —
   after files are swapped but before the relaunch/handoff.
2. **Runtime requirement.** Every machine that runs the tool must have the module
   present, and on 5.1 it must be installed into the 5.1 module path specifically.

Removing the dependency eliminates both problems while preserving the tool's
behavior and look-and-feel.

## Goals

- Remove **all** uses of `PwshSpectreConsole` from code (`*.ps1`) and from the
  installer.
- Preserve the existing behavior and a close approximation of the look: colored
  output, section structure, prompts with the same defaults, summary, and table.
- Keep the Pester suite green (currently 49/49 in `New-LocalUser.Tests.ps1`).

## Non-goals

- No new UI features or restyling beyond replacing Spectre.
- We do **not** uninstall `PwshSpectreConsole` from machines that already have it;
  it simply becomes unused.
- No animated spinner (Spectre's `Invoke-SpectreCommandWithStatus` animation is
  replaced by a static status line).
- Unicode box-drawing is **not** used (chosen "Clean ASCII + colors" fidelity), so
  output renders correctly on legacy stock consoles.

## Approach

Introduce one dot-sourced helper file, `src/Pwsh-NewLocalUser/ConsoleUI.ps1`,
containing native (no external module) functions with neutral names. `New-LocalUser.ps1`
dot-sources it instead of importing Spectre, and each Spectre call is replaced by the
corresponding helper. This isolates all rendering in one testable file, keeps
`New-LocalUser.ps1` readable, and lets the Pester suite mock the new names.

(Alternatives considered: inline `Write-Host`/`Read-Host` at every call site —
scatters markup-parsing logic and bloats the script; or keeping the `Write-Spectre*`
names with a native body — misleading once Spectre is gone.)

## Component: `ConsoleUI.ps1`

All functions are plain PowerShell, compatible with Windows PowerShell 5.1 and
PowerShell 7. No `using`/module imports.

| Helper | Replaces | Signature | Behavior |
|---|---|---|---|
| `Write-AppHost` | `Write-SpectreHost` | `-Message [string]`, `-NoNewline [switch]` | Parse `[color]…[/]` markup, render via `Write-Host -ForegroundColor`. See markup rules below. Passes `-NoNewline` through. |
| `Show-AppBanner` | `Write-SpectreFigletText` | `-Text [string]` | Blank line, then `=====  <Text>  =====` (decorative `=` bars around the text), then blank line. |
| `Show-AppRule` | `Write-SpectreRule` | `-Title [string]` | Blank line, then `--- <Title> ---`. |
| `Read-AppText` | `Read-SpectreText` | `-Message [string]`, `-DefaultAnswer [string]` | Prompt `"<Message> [<DefaultAnswer>]: "`, read input; blank/whitespace → return `$DefaultAnswer`, else return the input (untrimmed; caller trims, as today). |
| `Read-AppConfirm` | `Read-SpectreConfirm` | `-Message [string]` | Default **Yes**. Prompt `"<Message> [Y/n]: "`; blank → `$true`; `^[Yy]` → `$true`; `^[Nn]` → `$false`; invalid → re-prompt. Returns `[bool]`. |
| `Show-AppSummary` | `Format-SpectrePanel` | `-Header [string]`, `-Data [string]` | Print `<Header>`, then each line of `$Data` indented two spaces. |
| `Invoke-AppStatus` | `Invoke-SpectreCommandWithStatus` | `-Title [string]`, `-ScriptBlock [scriptblock]` | Print `<Title>`, then run `& $ScriptBlock` (returns its output/side effects). No spinner. |
| *(none — native)* | `Format-SpectreTable` | n/a | Call site changes to `… | Format-Table -AutoSize`. |

### Markup parsing (`Write-AppHost`)

Spectre messages embed markup like `[yellow]warn[/]`, `[grey]…[bold]Enter[/]…[/]`.

- Determine the line color from the **first** recognized color tag in the message.
- **Strip all** `[...]` and `[/]` tokens from the text (including `[bold]`; nested
  inner tags are removed — the line is rendered in the single outer color, inner
  emphasis/`bold` is not separately styled, because `Write-Host` cannot bold without
  raw ANSI, which we avoid on stock consoles).
- Color map (Spectre tag → `System.ConsoleColor`): `grey`→`DarkGray`, `yellow`→`Yellow`,
  `red`→`Red`, `green`→`Green`, `cyan`→`Cyan`. Unrecognized/no tag → default
  foreground (call `Write-Host` without `-ForegroundColor`).
- Messages with no markup (e.g. `'Password: '`) render as-is.

## Call-site changes: `src/Pwsh-NewLocalUser/New-LocalUser.ps1`

- **Remove** line 39 `$env:IgnoreSpectreEncoding = $true` and line 40
  `Import-Module PwshSpectreConsole -ErrorAction Stop`.
- **Add** dot-source: `. (Join-Path $PSScriptRoot 'ConsoleUI.ps1')` (in the same
  "Console UI" section; keep the UTF-8 encoding line at 38).
- **Update** `.NOTES` (line 19): drop "PwshSpectreConsole module" from Requires.
- Replace each call (line numbers from current `dev`):

| Line(s) | From | To |
|---|---|---|
| 108, 174, 175, 191, 201, 217, 232, 237, 258, 285, 306, 309, 332, 378 | `Write-SpectreHost '<markup>'` | `Write-AppHost '<markup>'` |
| 172 | `Write-SpectreHost '[grey]…[bold]Enter[/]…[/]'` | `Write-AppHost` (nested markup → outer grey) |
| 181, 196 | `Write-SpectreHost '… ' -NoNewline` | `Write-AppHost '… ' -NoNewline` |
| 163 | `Write-SpectreFigletText -Text 'New Local User'` | `Show-AppBanner -Text 'New Local User'` |
| 166, 222, 244, 276, 305 | `Write-SpectreRule -Title '<t>'` | `Show-AppRule -Title '<t>'` |
| 229 | `Read-SpectreText -Message 'Username' -DefaultAnswer $suggested` | `Read-AppText -Message 'Username' -DefaultAnswer $suggested` |
| 211, 256, 311, 314 | `Read-SpectreConfirm -Message '<m>'` | `Read-AppConfirm -Message '<m>'` |
| 254 | `Format-SpectrePanel -Header 'New User Summary' -Data $summaryText` | `Show-AppSummary -Header 'New User Summary' -Data $summaryText` |
| 265 | `Invoke-SpectreCommandWithStatus -Title 'Creating local user...' -ScriptBlock {…} -Spinner Dots` | `Invoke-AppStatus -Title 'Creating local user...' -ScriptBlock {…}` (drop `-Spinner`) |
| 296 | `} | Format-SpectreTable` | `} | Format-Table -AutoSize` |

## Installer change: `install.ps1`

- **Remove** Step 8 entirely (lines 191–197 on `dev`: the
  `Get-Module PwshSpectreConsole -ListAvailable` check and `Install-Module`).
- Renumber the trailing "Step 9: Prompt to run" comment to "Step 8".

## Test changes: `tests/Pester/New-LocalUser.Tests.ps1`

- **Setup (lines 48–51):** remove `$env:IgnoreSpectreEncoding` and
  `Import-Module PwshSpectreConsole`; dot-source the helper so the functions exist
  for mock registration: `. (Join-Path $PSScriptRoot '..\..\src\Pwsh-NewLocalUser\ConsoleUI.ps1')`.
  Keep the UTF-8 encoding line.
- **Remove** `Mock Import-Module { }` (line 102) — the SUT no longer imports.
- **Rename mocks (lines 105–126):**
  - `Write-SpectreFigletText` → `Show-AppBanner`
  - `Write-SpectreRule` → `Show-AppRule`
  - `Write-SpectreHost` → `Write-AppHost`
  - `Format-SpectrePanel` → `Show-AppSummary`
  - `Format-SpectreTable` → **drop** (now native `Format-Table`; output suppressed by `*>$null`)
  - `Out-SpectreHost` → **drop** (was unused)
  - `Invoke-SpectreCommandWithStatus { param($Title,$ScriptBlock,$Spinner,$Color,$SpinnerStyle) & $ScriptBlock }` → `Invoke-AppStatus { param($Title,$ScriptBlock) & $ScriptBlock }`
  - `Read-SpectreText` → `Read-AppText`
  - `Read-SpectreConfirm` → `Read-AppConfirm` (mock body unchanged: matches on `$Message`)
- **Rename assertions:** `Should -Invoke Write-SpectreHost` → `Write-AppHost`
  (lines 251, 287, 330, 662); `Read-SpectreText` → `Read-AppText` (lines 343, 349,
  376); `Read-SpectreConfirm` → `Read-AppConfirm` (line 711). `ParameterFilter`
  blocks reference `$Message`, which the new helpers preserve — no filter changes.
- **Update doc comment** (lines 7–22, 36) to name the new helpers.

## Docs change: `docs/NEW-LOCALUSER.md`

- Remove the `PwshSpectreConsole` prerequisite/requirement mention.

## Testing & verification

1. **Pester:** `Invoke-Pester ./tests/Pester/New-LocalUser.Tests.ps1` → all tests
   pass (expect 49/49). Also run the full `./tests/Pester` directory to confirm no
   regressions elsewhere.
2. **No Spectre left in code:** grep is empty for `Spectre` across `*.ps1`
   (`src/`, `scripts/`, `install.ps1`, `tests/`). (Historical `docs/plans/*` are not
   modified; `docs/NEW-LOCALUSER.md` is updated.)
3. **No module dependency at runtime:** launch `New-LocalUser.ps1` non-interactively
   under both Windows PowerShell 5.1 and PowerShell 7 (elevated). It must print the
   banner + "Password" rule and reach the `Read-Host` password prompt **without**
   importing or requiring `PwshSpectreConsole`. (The non-interactive `Read-Host`
   failure is the expected, safe stop — no account is created.)
4. **Installer:** confirm `install.ps1` no longer references the module and runs its
   install/update flow without the Step 8 PSGallery call.

## Acceptance criteria

- Zero `Spectre`/`PwshSpectreConsole` references in `*.ps1` and `install.ps1`.
- `New-LocalUser.Tests.ps1` passes at its current count; full Pester dir has no new
  failures.
- `New-LocalUser.ps1` runs to the password prompt with the module absent, on 5.1 and 7.
- `install.ps1` no longer installs `PwshSpectreConsole`.
- Behavior preserved: confirms default to **Yes** (`[Y/n]`); username prompt keeps
  its default; colored messages keep their dominant color.
