# Changelog

Each release is a Git tag `v<version>` that matches `$StoreLtscVersion` in `install.ps1`. To run a specific release, use its tag in the address:

```powershell
irm https://raw.githubusercontent.com/Softhe/Store-LTSC/v1.0.0/install.ps1 | iex
```

## [1.0.0] - Unreleased

The first tagged release. It contains everything the script did before releases existed, plus the changes below.

### Added

- The script checks Windows before it installs anything. It reports disabled services the Store needs (Windows Update, Microsoft Store Install Service, Client License Service, Windows License Manager, Delivery Optimization, Web Account Manager, AppX Deployment Service and State Repository Service) and Group Policies that turn off the Store or block its downloads. A disabled AppX Deployment Service or State Repository Service stops the run with the new exit code 9, because app installation cannot work without them.
- `-FixServices` sets disabled services the Store needs back to Manual. Windows refuses to let administrators change AppX Deployment Service, Client License Service and Delivery Optimization while it runs, so the script changes their registry setting, which Windows applies at the next restart. If AppX Deployment Service is among them, the run stops with exit code 9 and asks you to restart Windows and run the installer again.
- If the registry already says Manual but Windows still treats AppX Deployment Service or State Repository Service as disabled, because nobody restarted after the change, the run stops with exit code 9 instead of failing halfway through the install.
- The online download compares the PC's clock with Microsoft's. When the clock is 5 or more minutes off, the summary asks you to fix it.
- Verification waits up to 20 seconds for an app that Windows is still finishing, for example while it adds a language pack, before it reports the app as not registered.
- After installing, the script runs `winget --version` as the current user to confirm that winget really starts.
- `-CollectLogs` saves a diagnostics zip for bug reports, with user, computer and domain names removed.
- `-TargetBuild` and `-TargetArch` let `-DownloadOnly` prepare an offline folder for another Windows build or architecture.
- The banner, the log and `-Help` show the script version.
- When the GitHub API refuses the winget license lookup, for example because of its hourly limit, the script reads the winget release page instead.
- A daily GitHub Actions job downloads the package set for LTSC 2021 x64, LTSC 2024 x64 and LTSC 2024 ARM64 from Microsoft and opens an issue when that fails.
- A bug report form asks for the Windows build, the exit code and the diagnostics zip.

### Changed

- The script decides whether a deployment error is harmless from its error code. It no longer depends on the English error text, and it asks Windows for the installed version instead of reading it from the message.
- Metadata requests are no longer retried after a permanent HTTP client error, such as 404. Timeouts, connection failures and server errors are still retried, and package downloads still retry every error.
- An install now has five numbered steps instead of four. Checking Windows is the first.
