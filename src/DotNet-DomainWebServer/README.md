# OsmUserWeb

A minimal ASP.NET Core 9 web server that replicates the functionality of [`New-OSMUser.ps1`](../PwshScript/README.md). It exposes a simple browser UI and a two-endpoint REST API for creating numbered Active Directory admin accounts.

## Prerequisites

| Requirement | Notes |
|---|---|
| .NET 9 SDK | [Download](https://dotnet.microsoft.com/download/dotnet/9) |
| Windows | `System.DirectoryServices` is Windows-only |
| Domain-joined machine | The server process must be able to reach a domain controller |
| Domain Admin (or equivalent) | Same permission requirements as the PowerShell script |

## Configuration

Edit `appsettings.json` before running:

```json
"AdSettings": {
  "DefaultPassword": "YourDefaultP@ssw0rd",
  "TargetOU":        "OU=AdminAccounts,DC=yourdomain,DC=com",
  "GroupName":       "Domain Admins"
}
```

| Key | Purpose |
|---|---|
| `DefaultPassword` | Password used when the UI password field is left blank |
| `TargetOU` | Full distinguished name of the OU where accounts are created |
| `GroupName` | AD security group the new account is added to |

For production deployments, supply secrets via environment variables or a secrets manager rather than editing `appsettings.json` directly:

```
AdSettings__DefaultPassword=S0meP@ss!
```

## Production Deployment

For a full production deployment — including service account setup, AD permission delegation, TLS configuration, Windows Service installation, and firewall hardening — see **[INSTALL.md](INSTALL.md)**.

The automated installer script performs every step in INSTALL.md from a single elevated PowerShell session:

```powershell
# Run on the target server (as Administrator)
.\Install-OsmUserWeb.ps1 -PublishPath .\publish
```

See [`Install-OsmUserWeb.ps1`](Install-OsmUserWeb.ps1) for the full parameter reference.

To completely remove OsmUserWeb — Windows Service, HTTP.sys registrations, firewall rules, and application files — run the uninstall script:

```powershell
# Full removal (as Administrator)
.\Uninstall-OsmUserWeb.ps1

# Also remove the service account from AD and the TLS certificate
.\Uninstall-OsmUserWeb.ps1 -RemoveServiceAccount -RemoveCertificate
```

See [`Uninstall-OsmUserWeb.ps1`](Uninstall-OsmUserWeb.ps1) for the full parameter reference.

## Build and Run

```powershell
cd src/DotNet-DomainWebServer
dotnet run
```

The server starts on **http://localhost:5150** by default (configured in `Properties/launchSettings.json`). Open that URL in a browser.

To change the port:

```powershell
dotnet run --urls "http://localhost:8080"
```

## Versioning

OsmUserWeb uses a three-part version number derived automatically at build time:

```
MAJOR . MINOR . PATCH  [+ SHA]
  │       │       │        └─ short git commit hash (InformationalVersion only)
  │       │       └────────── git rev-list --count HEAD
  │       └────────────────── version.json  ← edit to bump
  └────────────────────────── version.json  ← edit to bump
```

**PATCH increments automatically with every commit** — no manual step required.

**MAJOR and MINOR** are stored in `version.json` at the repository root and are the only values that need to be edited for significant releases:

```json
{
  "major": 1,
  "minor": 0
}
```

### Producing a versioned build

Use the build script from the repository root. It reads `version.json`, queries git for the commit count and short SHA, injects both into the binary, and names the zip artifact accordingly:

```powershell
# Framework-dependent, no zip
.\Build-OsmUserWeb.ps1

# Self-contained, zipped for hand-off  →  OsmUserWeb-v1.0.47-win-x64.zip
.\Build-OsmUserWeb.ps1 -SelfContained -ZipOutput
```

The resulting distribution folder contains a `version.txt` manifest:

```
OsmUserWeb Build Manifest
=========================
Version              : 1.0.47
InformationalVersion : 1.0.47+a3f2c1d
Configuration        : Release
Runtime              : win-x64
Self-contained       : False
Build date (UTC)     : 2026-02-25 14:30:00 UTC
```

The same version is embedded in the binary's `FileVersion` and `InformationalVersion` metadata, visible in Windows Explorer → Properties → Details.

### Development builds

Plain `dotnet build` / `dotnet run` (without the build script) produce a binary stamped `0.0.0+local`. This is expected and harmless for local development.

### Bumping MAJOR or MINOR

1. Edit `version.json` — increment `major` or `minor`, reset `minor` to `0` if bumping `major`.
2. Commit the change.
3. Run `.\Build-OsmUserWeb.ps1` — the new version takes effect immediately from that commit onward.

### Shallow clones

If the repository was cloned with `--depth`, the git commit count will be lower than the true value and the PATCH number will be inaccurate. Unshallow before building for release:

```powershell
git fetch --unshallow
```

## Web UI Workflow

The UI mirrors the two-step flow of the PowerShell script:

1. **Enter optional fields** — Base Name (default: derived from the server process user by stripping trailing digits) and Password (default: config value).
2. **Click Preview** — Calls `GET /api/preview` and shows the same summary table as the cyan box in the PowerShell script.
3. **Click Create Account** — Calls `POST /api/users` and displays the verified account details on success.

## REST API

### `GET /api/preview`

Returns the next username that would be created without making any changes.

**Query parameters**

| Parameter | Required | Description |
|---|---|---|
| `baseName` | No | Override the base name. Defaults to the server process username with trailing digits stripped. |

**200 response**

```json
{
  "username": "erik81",
  "upn":      "erik81@contoso.com",
  "targetOU": "OU=AdminAccounts,DC=contoso,DC=com",
  "groupName":"Domain Admins"
}
```

**Error responses** — `400 Bad Request` (empty base name), `422 Unprocessable Entity` (OU not found), `500 Internal Server Error` (AD unreachable).

---

### `POST /api/users`

Creates the AD account, sets `CannotChangePassword`, adds to the configured group, and returns the verified user object.

**Request body**

```json
{
  "baseName": "erik",
  "password": "S0meP@ss!"
}
```

Both fields are optional (same defaults as the query parameter above).

**201 response**

```json
{
  "name":                   "erik81",
  "samAccountName":         "erik81",
  "userPrincipalName":      "erik81@contoso.com",
  "enabled":                true,
  "passwordNeverExpires":   true,
  "userCannotChangePassword": true,
  "memberOf":               "Domain Admins",
  "ou":                     "OU=AdminAccounts,DC=contoso,DC=com"
}
```

**Error responses** — `400 Bad Request` (empty base name), `409 Conflict` (race condition — username exists), `500 Internal Server Error` (AD write failure).

## Account Properties

Every account created has the same properties as the PowerShell script:

| Property | Value |
|---|---|
| Name / DisplayName / GivenName / SamAccountName | `<base><N>` (e.g., `erik81`) |
| UserPrincipalName | `<base><N>@<domain.dns.root>` |
| Enabled | `True` |
| PasswordNeverExpires | `True` |
| UserCannotChangePassword | `True` |
| ChangePasswordAtLogon | `False` (implied by `PasswordNeverExpires`) |
| OU | As configured in `TargetOU` |
| Group membership | As configured in `GroupName` |

## Project Structure

```
src/DotNet-DomainWebServer/
├── OsmUserWeb.csproj          # .NET 9 web project
├── Program.cs                 # Minimal API entry point and route definitions
├── appsettings.json           # Configuration (AD settings, logging)
├── Models/
│   └── AdModels.cs            # Record types for settings, requests, and responses
├── Services/
│   └── AdUserService.cs       # All Active Directory operations
├── Properties/
│   └── launchSettings.json    # Dev port (5150) and browser launch config
└── wwwroot/
    └── index.html             # Single-page UI (no external dependencies)
```

## Differences from the PowerShell Script

| Aspect | PowerShell script | Web server |
|---|---|---|
| "Current user" for base name | `$env:USERNAME` of the terminal session | `Environment.UserName` of the server **process** (often a service account) — supply `baseName` explicitly to override |
| Confirmation prompt | Interactive `Read-Host Y/N` | Two-step UI: Preview → Create |
| Password input | `-Password` parameter or config | Password field in the UI or `POST` body |
| Concurrent use | Single operator at a time | Multiple operators can use the web UI simultaneously; race conditions are handled with a `409 Conflict` response |
| Audit trail | Console output | Structured ASP.NET Core logs |

## Security Notes

- The API accepts passwords in the POST body over HTTP. **Configure HTTPS** for any non-localhost deployment.
- The server process account must have sufficient AD permissions. Avoid running as Domain Admin if a delegated OU admin account can be used instead.
- `DefaultPassword` in `appsettings.json` is a placeholder — replace it and consider injecting it via an environment variable or secrets manager.
