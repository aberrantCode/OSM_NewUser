# OSM New User Tools

A collection of Windows account-creation utilities for local and domain administrators.

## Components

| Tool | Purpose | Docs |
|---|---|---|
| `scripts/Start-App.ps1` → `src/Pwsh-NewLocalUser/New-LocalUser.ps1` | Create a numbered **local** Windows administrator account interactively | [docs/NEW-LOCALUSER.md](docs/NEW-LOCALUSER.md) |
| `src/PwshScript/New-OSMUser.ps1` | Create a numbered **Active Directory** domain admin account | [src/PwshScript/README.md](src/PwshScript/README.md) |
| `src/DotNet-DomainWebServer/` | ASP.NET Core web server for domain account creation | [src/DotNet-DomainWebServer/README.md](src/DotNet-DomainWebServer/README.md) |

## Quick Start — Local User

1. Copy `.env.example` to `.env` and set `NEW_USER_PASSWORD`
2. Run `scripts\Start-App.ps1` (auto-elevates if needed)

See [docs/NEW-LOCALUSER.md](docs/NEW-LOCALUSER.md) for full documentation.

## Quick Start — Domain User (AD)

See [src/PwshScript/README.md](src/PwshScript/README.md).

## Quick Start — Domain Web Server

See [src/DotNet-DomainWebServer/README.md](src/DotNet-DomainWebServer/README.md).

## Repository Structure

```
OSM_NewUser/
├── scripts/                        # Launchers
│   └── Start-App.ps1               # Auto-elevating entry point for local user tool
├── src/
│   ├── Pwsh-NewLocalUser/          # Local Windows admin account creation
│   ├── PwshScript/                 # AD domain admin account creation
│   ├── DotNet-DomainWebServer/     # ASP.NET Core web server
│   └── DotNet-DomainWebServer.Tests/  # xUnit tests
├── tests/
│   └── Pester/                     # Pester 5 tests for PowerShell scripts
├── docs/                           # Additional documentation
├── hooks/                          # Git hooks
└── .env.example                    # Password configuration template
```

## Security Notes

- `.env` is gitignored. Never commit it.
- A pre-commit hook (`hooks/pre-commit`) is included to block accidental `.env` commits.
- Activate with: `git config core.hooksPath ./hooks`
