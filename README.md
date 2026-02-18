# New-OSMUser.ps1

A PowerShell utility for domain administrators to quickly create numbered admin accounts in Active Directory. It auto-increments based on existing accounts, so running it twice produces sequential usernames (e.g., `erik80`, `erik81`, `erik82`).

## Prerequisites

- **Windows PowerShell 5.1+** (or PowerShell 7+)
- **Active Directory RSAT tools** installed on the workstation
- The executing user must be a **Domain Admin** (or have equivalent permissions to create users, modify group membership, and read the target OU)

### Installing RSAT

| Platform | Command |
|---|---|
| Windows Server | `Install-WindowsFeature RSAT-AD-PowerShell` |
| Windows 10/11 | `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` |

## Configuration

Open `New-OSMUser.ps1` and edit the three variables at the top of the configuration section (lines 30-32):

```powershell
$DefaultPassword = 'YourDefaultP@ssw0rd'                        # Default password for new accounts
$TargetOU        = 'OU=AdminAccounts,DC=yourdomain,DC=com'      # Distinguished name of the target OU
$GroupName       = 'Domain Admins'                               # Group to add the new user to
```

| Variable | Purpose | Required |
|---|---|---|
| `$DefaultPassword` | Password assigned to the new account when `-Password` is not specified | Yes |
| `$TargetOU` | Full distinguished name of the OU where the account will be created | Yes |
| `$GroupName` | AD security group the new account is added to | Yes |

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-BaseName` | String | Derived from `$env:USERNAME` | Override the base name used for account numbering. By default the script strips trailing digits from the current Windows username (e.g., `erik80` becomes `erik`). |
| `-Password` | String | `$DefaultPassword` config value | Override the password assigned to the new account. |
| `-Verbose` | Switch | Off | Built-in PowerShell common parameter. Enables step-by-step diagnostic output. |

## Usage

```powershell
# Use defaults: base name from current login, default password
.\New-OSMUser.ps1

# Override the base name
.\New-OSMUser.ps1 -BaseName "admin"

# Override the password
.\New-OSMUser.ps1 -Password "S0meOtherP@ss!"

# Both overrides with verbose diagnostics
.\New-OSMUser.ps1 -BaseName "svc" -Password "X" -Verbose
```

## How It Works

The script follows this sequence:

1. **Import AD module** -- Loads `ActiveDirectory`. Fails with installation instructions if RSAT is not present.
2. **Resolve base name** -- Strips trailing digits from `$env:USERNAME` (e.g., `erik80` -> `erik`), or uses the `-BaseName` parameter if provided.
3. **Verify target OU** -- Confirms the configured `$TargetOU` exists in AD before proceeding.
4. **Query existing accounts** -- Runs `Get-ADUser -Filter "SamAccountName -like '<base>*'"`, then regex-filters results to match only `^<base>\d+$` (exact base name followed by one or more digits).
5. **Compute next number** -- Takes the highest existing number and adds 1. If no numbered accounts exist, starts at 1.
6. **Display summary** -- Shows a confirmation prompt with all account details. User must type `Y` or `Yes` to proceed.
7. **Create user** -- Calls `New-ADUser` with splatted parameters for all required properties.
8. **Set CannotChangePassword** -- Applied via `Set-ADUser` post-creation to avoid a known `New-ADUser` bug that can cause "Access Denied" when setting this flag inline.
9. **Add to group** -- Adds the new account to the configured group (default: Domain Admins). This step has separate error handling so a group-add failure doesn't hide the fact that the user was created.
10. **Verify and report** -- Reads the account back from AD and displays all configured properties in a green success summary.

## Account Properties

Every account created by this script has the following properties:

| Property | Value |
|---|---|
| Name | `<base><N>` (e.g., `erik81`) |
| DisplayName | `<base><N>` |
| GivenName | `<base><N>` |
| SamAccountName | `<base><N>` |
| UserPrincipalName | `<base><N>@<domain.dns.root>` |
| Enabled | `True` |
| PasswordNeverExpires | `True` |
| ChangePasswordAtLogon | `False` |
| CannotChangePassword | `True` |
| Member of | Domain Admins (configurable) |
| OU | As configured in `$TargetOU` |

## Error Handling

The script uses `$ErrorActionPreference = 'Stop'` and wraps critical operations in `try/catch` blocks:

| Scenario | Behavior |
|---|---|
| RSAT not installed | Red error with installation commands for both Server and Desktop Windows |
| Base name resolves to empty | Red error prompting to use `-BaseName` |
| Target OU does not exist | Red error prompting to update `$TargetOU` in the script |
| Race condition (duplicate SAMAccountName) | Red error explaining another admin may have created the account; advises re-running |
| User creation fails (other) | Red error with the exception message |
| CannotChangePassword fails | Yellow warning; user was still created |
| Group membership fails | Yellow warning with manual remediation instructions; user was still created |
| User cancels at Y/N prompt | Yellow abort message; no changes made |

## Output Colors

| Color | Meaning |
|---|---|
| Cyan | Pre-creation summary |
| Green | Success / verification report |
| Yellow | Abort or non-fatal warning |
| Red | Fatal error |

## Example Session

```
PS C:\> .\New-OSMUser.ps1

╔══════════════════════════════════════════╗
║       New AD User -- Summary             ║
╠══════════════════════════════════════════╣
║  Username:            erik81
║  UPN:                 erik81@contoso.com
║  Target OU:           OU=AdminAccounts,DC=contoso,DC=com
║  Group:               Domain Admins
║  Enabled:             True
║  PasswordNeverExpires: True
║  CannotChangePassword: True
║  ChangePasswordAtLogon: False
╚══════════════════════════════════════════╝

Create this account? (Y/N): Y

  Account created successfully!

  Name:                  erik81
  SamAccountName:        erik81
  UPN:                   erik81@contoso.com
  Enabled:               True
  PasswordNeverExpires:  True
  CannotChangePassword:  True
  Member of:             Domain Admins
  OU:                    OU=AdminAccounts,DC=contoso,DC=com
```

## Verification Checklist

After deploying the script to your environment:

1. Run `.\New-OSMUser.ps1 -Verbose` and confirm the summary shows the correct username, OU, and group
2. Type `Y` and verify the account appears in AD Users and Computers with all expected properties
3. Run the script again to confirm the number increments (e.g., `erik81` -> `erik82`)
4. Test `-BaseName "testacct"` to verify alternate base names work and number independently
5. Test cancelling at the Y/N prompt to confirm no account is created
6. Verify the account can log in with the configured password
