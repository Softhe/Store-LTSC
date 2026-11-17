# Installer reliability

## Installation and downloads

Use the named options in `install.ps1`. The script supports Windows PowerShell 5.1 and relaunches in Windows PowerShell when Appx deployment requires it. Relaunch runs a snapshot of the executing script, with the same parameters, rather than downloading another revision from GitHub.

The online command runs parameter binding and implementation variables in child scopes. It reports its result through `$LASTEXITCODE` without deleting existing variables from the calling session.

Each default download folder has a unique name under the temporary directory. The script deletes that folder only when its path and ownership marker match the current run. `-KeepDownloads`, `-DownloadOnly`, and an explicit `-DownloadDir` preserve downloads. The log file records the selected folder. Download-only runs also print it at the end.

`-DownloadTimeoutSeconds` limits each package download attempt. The default is 1800 seconds, and the accepted range is 1 through 86400 seconds. The downloader stops a transfer that exceeds this limit, or that receives no data for 60 seconds. Metadata requests have separate timeouts. Retries mean the total run can take longer than one download deadline.

Downloads use one unique temporary file per package. A retry resumes that file with an HTTP range request. The script checks the service-provided hash and Microsoft signature before replacing the destination package, and discards a file that fails or cannot complete verification. The temporary file is removed when the package succeeds or the retries are exhausted. The transfer is read in small blocks, so Ctrl+C is answered promptly. An interrupted run still removes its own temporary download folder.

## Windows versions

The Store service offers the same packages to every Windows build; it does not filter by the build the script reports. On 2026-11-17 it offered identical lists for builds 17763, 19044, and 26100. The script therefore reads the `TargetDeviceFamily` minimum version from each downloaded app. If the best-ranked version does not support the machine, the script removes it and tries the next version on offer. With no usable Microsoft Store version, the run ends with code 8.

On that date, the current packages declared these minimum builds: Microsoft Store 18362, Store Purchase App 18362, Xbox Identity Provider 16299, and App Installer 17763. All support LTSC 2021 (build 19044). LTSC 2019 (build 17763) is below the current Store's minimum; the service still offers Store 12107, which declares 16299, but the script's own minimum remains build 19041 until that path is tested on a real system.

App Installer bundles list a stub payload for each architecture before the real one, with a backslash in its path. The script ignores stub payloads and reads the real payload for the machine's architecture.

## Running again

An app is compared the same way as a framework. If the same or a newer version is already provisioned, or registered for the current user with status `Ok`, that step is skipped and the package is reported as already installed. A registered bundle app reports its payload version, so App Installer `2026.917.151.0` is recognised as registered version `1.29.380.0`. Xbox Identity Provider is the one exception to version ordering: its legacy `2017.x` line is older than `12.x` and is replaced. If a newer copy exists on the machine but the current user has none, the script registers that copy by family name.

## Console

In a console window, the step in progress is one line that is rewritten in place. Deployment cmdlets run on a second runspace so the script can show the elapsed time and any progress the cmdlet reports. When output is redirected, the cmdlets are called directly and only permanent lines are written. A relaunch from PowerShell 7 shares the same console window, and the child receives a module path that suits Windows PowerShell. A Windows PowerShell process that inherited PowerShell 7's module path repairs it for the run and restores it afterwards.

If a requested companion app is unavailable, the script records a partial failure. This applies to download-only runs and local installations as well. `-SkipWinget` intentionally excludes App Installer from the requested set.

## Offline package folders

Online downloads produce `store-packages.json` beside the packages. It records the downloading machine's architecture and build, the requested and missing app families, and each file's size and SHA-256 hash.

When this manifest is present, local installation validates its schema, filenames, target architecture, requested components, sizes, hashes, and Microsoft signatures. It installs only files listed in the manifest. A manifest that records a missing requested app is rejected. A missing winget package does not block a run that uses `-SkipWinget`.

The JSON manifest detects corruption and incomplete transfers. Its hashes do not establish authenticity because users can edit the file. Microsoft signature validation establishes package authenticity. Keep the manifest with the downloaded packages when copying an offline folder.

Legacy folders without a JSON manifest remain supported. They do not receive the downloader's independent hash and Microsoft-signer verification. Windows still performs its deployment validation. The script reads identities and dependencies from package contents, including renamed files and bundle payloads.

Local selection skips packages with an unsupported architecture or Windows version before choosing the newest usable app. Equal versions prefer the native architecture. Bundles use their highest-ranked compatible architecture payload for dependency and Windows-version checks.

Frameworks install in dependency order. Before deployment, the script checks required names, publishers, versions, and architectures against the supplied frameworks and applicable installed or provisioned packages. Missing Microsoft Store dependencies and framework cycles stop the run before installation. A companion app with missing dependencies is skipped, and the run reports a partial failure, so it cannot block the Store. Packages that are not part of the Store set are ignored. Keep the complete framework set in an offline folder.

Relative `-WorkDir`, `-LogDir`, and `-DownloadDir` paths resolve against the current PowerShell location before any relaunch. `-Source Local` without `-WorkDir` uses the current PowerShell location. The elevated or 64-bit child receives the resolved paths.

## Framework selection

The Store service offers frameworks for every version of each app. The same LTSC 2024 run downloaded and installed 22 frameworks, including `Microsoft.UI.Xaml.2.4` and `Microsoft.NET.Native` 1.3 and 1.7, without checking whether the selected apps used them.

Online mode now downloads the selected apps first and reads the dependencies in their manifests. For bundles, it reads the payload for the best architecture on this machine. It then downloads only the offered frameworks that match a declared name, publisher, architecture, and minimum version, and repeats for those frameworks' own dependencies. Before installation, local and offline folders follow the same rule: frameworks that no app declares are skipped and logged. Download-only manifests list only the files that were downloaded.

## Newer frameworks and post-install verification

The Store service can offer a framework older than one already on the system. On a 2026-10-29 LTSC 2024 test (build 26100.9457), it offered `Microsoft.UI.Xaml.2.8` 8.2501.31001.0 while 8.2511.26001.0 was installed. Provisioning failed with `Element not found`, and current-user registration returned `0x80073D06`. Store and its companions still worked, but the run exited with code 5.

The installer now checks for the same framework name, publisher, and architecture at the same or a newer version. If one is provisioned, it skips provisioning. If one is registered for the current user, it skips registration. If provisioning fails while a newer copy is installed for any user, the installer records a warning instead of a failure.

Verification then decides the result. It checks current-user registration status for each installed app. When provisioning, it checks that every app, each manifest dependency, and the dependencies of installed frameworks are provisioned at the required version and architecture. A framework copy registered for the current user is reused only when its status is `Ok`. A dependency that new users would lack is a partial failure. A Store that is not registered after installation is a Store failure. The summary lists each failure by name.

## Exit codes

Existing exit codes remain in use. Code 4 also covers invalid or incompatible package metadata and missing dependencies. Code 5 means a requested app or deployment step failed, or verification could not confirm a companion app or a new-user dependency. It also covers an incomplete download-only set. Code 6 also covers a Store that is not registered after installation. Code 7 covers invalid offline manifests and other fatal errors. Code 8 covers online lookup, transfer, and verification failures for required downloads.

## Validation

Run the isolated regression suite on Windows:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Run-Tests.ps1
pwsh.exe -NoProfile -NonInteractive -File .\tests\Run-Tests.ps1
```

The tests use the installer's actual functions and main orchestration with fixture packages and mocked deployment calls. They cover caller scope, relaunch snapshots and arguments, relative path resolution, the command launcher's `-Source` default, cleanup ownership, package selection, dependencies, superseded frameworks, post-install verification, offline manifests, incomplete requested sets, and cancellation of a stalled loopback HTTP transfer. GitHub Actions runs the suite under both PowerShell engines.

These tests do not install packages or exercise UAC. They do not prove that Microsoft's live delivery service offers an installable package set for a particular LTSC image. Before release, test online and offline installation on disposable LTSC 2021 and LTSC 2024 systems, including SYSTEM provisioning and a new user's first sign-in. Check that Microsoft Store opens, winget runs, and the expected packages register for the intended users.
