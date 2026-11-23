# How it works

## Checking Windows

Before it downloads or installs anything, the script reads the start type of each service the Store depends on from the registry. It reads the registry because Get-Service does not always show protected services such as ClipSVC. A disabled AppX Deployment Service or State Repository Service stops the run with exit code 9, because Windows cannot install apps without them. A disabled Windows Update, Microsoft Store Install Service, Client License Service, Windows License Manager, Delivery Optimization or Web Account Manager does not stop the run, but the Store cannot download, license or sign in without it. The summary lists each of these services again. With `-FixServices`, the script sets each disabled service to Manual through the service manager. The service manager refuses that change to administrators for AppX Deployment Service, Client License Service and Delivery Optimization; only TrustedInstaller may reconfigure AppX Deployment Service. For those services the script writes the registry value instead. Windows reads that value only when it starts, so until the next restart it keeps treating the service as disabled, even though `sc qc` and Get-Service already report Manual. A required service changed this way stops the run with exit code 9 and a request to restart Windows. Because the registry can't show whether that restart has happened, the script also starts AppX Deployment Service and State Repository Service when they are stopped. If Windows refuses with error 1058 (the service is disabled), the run stops the same way.

The script also reports the Group Policies `RemoveWindowsStore` (machine and user), `DisableStoreApps` and `DoNotConnectToWindowsUpdateInternetLocations` when they are set to 1. It never changes policies. On Windows Server it warns that Server is not a tested target. Download-only runs skip these checks.

At the start of an online download, the script compares the PC's clock with the `Date` header of Microsoft's catalog service. When the difference is 5 minutes or more, it asks you to fix the clock, because a wrong clock can break Store sign-in and app licenses. The download itself doesn't depend on the clock: on 2026-11-24 the delivery service served the full package set to a PC whose clock was 20 minutes fast, and to one that was a day fast or a day slow.

## Choosing and downloading packages

Online, the script looks up each app in Microsoft's Store catalog and asks the Store delivery service for its packages. It ranks app packages by the service's package rank, then by version and architecture. It downloads the chosen apps first and reads the dependencies in their manifests. It then downloads only those frameworks, at the newest offered version for each architecture. Local folders follow the same rule, and the script skips frameworks that no app declares. Apps you install later from Microsoft Store bring their own dependencies.

Microsoft's service offers the same packages to every Windows build, so the script reads the minimum Windows version that each app declares. When the newest version of an app does not support the machine, the script tries the next version on offer.

For each download, the script checks the file size and the hash that Microsoft supplies over HTTPS. It uses SHA-256 when available and SHA-1 otherwise. It also requires a valid Microsoft Corporation code signature before it replaces the destination file. A transfer stops after 60 seconds without data, or when it runs past `-DownloadTimeoutSeconds`. The script then retries and resumes the partial file. It deletes a file that fails verification and downloads it again from the start.

The online download uses an undocumented Microsoft service, and a change to that service can break it. Local mode uses only the packages you already have.

## Local packages

For local packages, the script reads identities and dependencies from the package manifests. It drops packages with an unsupported architecture or Windows version before it picks the apps. A missing Microsoft Store dependency or a framework dependency cycle stops the run before the script installs anything. If a companion app lacks a dependency, the script skips that app and reports a partial failure. The script installs only the Store set and ignores other packages in the folder.

## Installing

The script installs frameworks in dependency order, then Microsoft Store, then the companion apps. By default it provisions each package for new users and registers it for the current user. `-NoProvision` skips provisioning. A requested companion app that is unavailable gives a partial failure, in download-only mode too.

Windows cannot install an older copy of a package that is already present, and the script does not roll back a Store that has updated itself. When the same framework or app is already provisioned or registered at the same or a newer version, the script skips that step and reports the package as already installed. If provisioning rejects a package because a newer one is installed, the script logs a warning and leaves the result to verification.

When it runs as SYSTEM, for example through Intune, SCCM or MDT, the script only provisions packages. Windows then registers them for each user at sign-in. Do not combine SYSTEM with `-NoProvision`.

## Verifying

After installing, the script asks Windows for the result. It checks that Windows registered each app for the current user with status `Ok`. Windows can leave out a package it is still servicing, for example while it adds a language pack, so the script waits up to 20 seconds for a missing app before it counts a failure. When App Installer is registered, the script runs `winget --version` through the user's App Execution Alias. Without its license, Windows refuses to start winget even though the package is registered. When provisioning, it also checks that each app and each of its dependencies is provisioned at the required version for new users. Anything the script cannot confirm counts as a partial failure, and the summary lists each failure by name. A missing winget license is counted once, not again when winget then fails to start.

Whether a deployment error is harmless depends on its code: `0x80073D06` (a higher version is installed) and `0x80073CFB` (the same package is installed). The script takes the code from the `HRESULT: 0x...` part of the error, which is the same in every Windows language. The exception's own HResult is often a mapped value, so the script uses it only when the text has no code. It then asks Windows for the version that is installed.

## Temporary files and restarts

Each run downloads into its own temporary folder. The script deletes that folder when the run ends, including after Ctrl+C, and first checks that the folder belongs to the run. `-KeepDownloads`, `-DownloadOnly` and a custom `-DownloadDir` keep the packages.

When the script restarts itself in Windows PowerShell or as administrator, the new process runs a copy of the same script with the same options.

See [installer reliability and validation](installer-reliability.md) for the offline manifest, the regression tests and the tests still needed before a release.
