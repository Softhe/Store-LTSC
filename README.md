# Store-LTSC

Installs the **Microsoft Store** (plus Store Purchase App, Xbox Identity Provider, **winget** and all
framework dependencies) on Windows 10/11 **LTSC / IoT Enterprise** editions, which ship without it.

Everything is downloaded straight from Microsoft's own Store delivery service — nothing is hosted here
except the script.

## Quick start

Open PowerShell (admin or not — a UAC prompt appears if needed) and run:

```powershell
irm https://raw.githubusercontent.com/Softhe/Store-LTSC/main/install.ps1 | iex
```

Reboot afterwards if this is a freshly installed LTSC/IoT system.

### With options

`irm | iex` cannot pass parameters, so use this form instead:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Softhe/Store-LTSC/main/install.ps1))) -SkipWinget
```

| Option | Effect |
|---|---|
| `-SkipWinget` | Don't install App Installer / winget (saves ~280 MB of downloads) |
| `-NoProvision` | Install for the current user only (no provisioning for new users) |
| `-DownloadOnly -DownloadDir D:\StorePkgs` | Only download the packages (no admin needed), e.g. to build an offline folder |
| `-Source Local -WorkDir D:\StorePkgs` | Install from a local folder instead of downloading |
| `-Source Auto -WorkDir D:\StorePkgs` | Use the local folder if it contains the Store package, otherwise download |
| `-KeepDownloads` | Keep the downloaded packages (`%TEMP%\StoreInstall-Packages`) |
| `-LogDir <path>` | Log folder (default `%TEMP%\StoreInstall-Logs` when run via `irm`) |

## Requirements

- Windows 10/11 build **19041** (20H1) or later — LTSC 2021, LTSC 2024, IoT Enterprise, etc.
- x64, ARM64 or x86
- Internet access to `displaycatalog.mp.microsoft.com`, `fe3.delivery.mp.microsoft.com` and
  `*.dl.delivery.mp.microsoft.com` (for online mode)

## How it works

1. Looks up each app's package family name in the Microsoft Store catalog
   (`displaycatalog.mp.microsoft.com`).
2. Asks the Store delivery service (`fe3.delivery.mp.microsoft.com` — the same backend the Store app and
   sites like store.rg-adguard.net use) for the app and its framework dependencies.
3. Picks the newest release of each app and the newest framework versions for your CPU architecture
   (x86 side-by-side frameworks are kept on x64/ARM64).
4. Downloads from Microsoft's CDN and **verifies every file**: it must match the SHA-256 hash the service
   published over HTTPS *and* carry a valid *Microsoft Corporation* code signature. Anything else is
   deleted and the run fails.
5. Provisions (all users) and installs (current user) frameworks first, then the Store, Store Purchase
   App, Xbox Identity Provider and App Installer.

Other behaviour:

- Re-launches itself in 64-bit Windows PowerShell when started from 32-bit PowerShell or PowerShell 7.
- When run via `irm | iex`, it runs inside a private module: it never closes your window and leaves no
  functions, variables or settings behind. The result is in `$LASTEXITCODE`.
- Running as **SYSTEM** (Intune, SCCM, MDT) provisions the packages for all users; they are registered at
  each user's next sign-in.
- Downloaded packages are deleted after installing (unless `-KeepDownloads` / `-DownloadDir`).

## Offline / double-click use

Download `install.ps1` and `Install-Store.cmd` into the same folder and double-click
`Install-Store.cmd`. It asks for admin rights, uses packages found in that folder (`-Source Auto`) and
otherwise downloads them. Optional license XMLs named `<PackageFamilyName>.xml` (e.g.
`Microsoft.WindowsStore_8wekyb3d8bbwe.xml`) placed next to the script are used when provisioning.

To prepare an offline folder on a machine with internet access:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Softhe/Store-LTSC/main/install.ps1))) -DownloadOnly -DownloadDir D:\StorePkgs
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Not elevated (or the UAC prompt was declined) |
| 2 | Unsupported Windows build (< 19041) |
| 3 | PowerShell is not in FullLanguage mode |
| 4 | Store package missing |
| 5 | Partial failure (Store installed, something else failed) |
| 6 | Store install failed |
| 7 | Fatal/internal error |
| 8 | Download failed (no internet, proxy/firewall, or Microsoft service unavailable) |

A timestamped log is written for every run (path shown at the start of the output). If the Store won't
open afterwards, check the log and *Event Viewer → Applications and Services Logs → Microsoft →
Windows → AppXDeployment-Server*.

## Notes

- The Store delivery service is not an officially documented API. It has been stable for years, but if
  Microsoft changes it the script fails cleanly with exit code 8; local mode keeps working.
- Without license XMLs, provisioning uses `-SkipLicense`, which works for these free apps.
