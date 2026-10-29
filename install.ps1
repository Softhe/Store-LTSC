#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the Microsoft Store (+ dependencies, optionally winget) on Win10/11 LTSC/IoT.

.DESCRIPTION
  One-liner (elevated or not; a UAC prompt is shown when needed):
    irm https://raw.githubusercontent.com/Softhe/Store-LTSC/main/install.ps1 | iex

  With options:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Softhe/Store-LTSC/main/install.ps1))) -SkipWinget

  - Downloads the latest packages straight from Microsoft's Store delivery service
    (displaycatalog.mp.microsoft.com + fe3.delivery.mp.microsoft.com, the same backend the
    Store app uses). Every download is checked against the published SHA-256 or SHA-1 hash
    and must carry a valid Microsoft Corporation signature.
  - Can also install from a local folder of packages (-Source Local / Auto).
  - Non-interactive, CI/MDT/SSH friendly (also runs as SYSTEM: provisions only)
  - Logging with timestamps
  - Dynamic license discovery (PackageFamilyName.xml) or -SkipLicense
  - Installs only the frameworks the apps declare (newest offered version per architecture)
  - Installs Store, StorePurchaseApp, XboxIdentityProvider, DesktopAppInstaller
  - Re-launches itself elevated (interactive sessions) and in 64-bit Windows PowerShell
    when started from 32-bit PowerShell or PowerShell 7

.PARAMETER WorkDir
  Folder with local packages and/or license XMLs. Default: script directory
  (none when run via irm | iex).

.PARAMETER LogDir
  Log directory. Default: <WorkDir>\Logs, or %TEMP%\StoreInstall-Logs when run via
  irm | iex or when WorkDir is not writable.

.PARAMETER Source
  Online (default) always download from Microsoft.
  Auto   use local packages if WorkDir contains a Microsoft.WindowsStore package, else download.
  Local  only use packages in WorkDir.

.PARAMETER DownloadDir
  Where downloaded packages go. Default: a unique %TEMP%\StoreInstall-Packages-<id> folder (deleted after install
  unless -KeepDownloads). A custom -DownloadDir is always kept.

.PARAMETER DownloadOnly
  Download packages for this machine's architecture and exit (no admin rights needed).
  Use it to prepare an offline folder: -DownloadOnly -DownloadDir D:\StorePkgs, then later
  run with -WorkDir D:\StorePkgs.

.PARAMETER KeepDownloads
  Do not delete the default download folder after installing.

.PARAMETER DownloadTimeoutSeconds
  Maximum duration of each package download attempt. Default: 1800 seconds.

.PARAMETER NoProvision
  Only Add-AppxPackage for current user (skip Add-AppxProvisionedPackage).

.PARAMETER SkipWinget
  Do not install DesktopAppInstaller even if the bundle is present (and do not download it).

.PARAMETER PauseAtEnd
  Wait for Enter before exiting (used for the elevated window opened by the UAC relaunch).

.NOTES
  Exit codes (also in $LASTEXITCODE when run via irm | iex):
    0 success
    1 not elevated (or UAC prompt declined)
    2 unsupported OS build
    3 PowerShell language mode not FullLanguage
    4 required package or dependency missing, incompatible, or invalid
    5 partial failure
    6 Store install failed
    7 fatal/internal
    8 download or download verification failed

  Tips:
    1. Needs admin rights; packages are downloaded from Microsoft (or taken from -WorkDir).
    2. License XMLs are optional; matched dynamically when present.
    3. Only frameworks the apps declare in their manifests are downloaded and installed.
    4. Failures are written to the log (nothing important is swallowed).
    5. Reboot after clean LTSC/IoT restores before relying on Store/winget.
#>

& {
param([object[]] $InvocationArguments, [string] $OriginalScriptPath)

# Keep parameter binding and all implementation variables out of the caller's scope.
$OriginalScriptText = '#Requires -Version 5.1' + [Environment]::NewLine + '& {' + [Environment]::NewLine + $MyInvocation.MyCommand.ScriptBlock.ToString() + [Environment]::NewLine + '} $args $PSCommandPath'
function Invoke-StoreLtsc {
[CmdletBinding()]
param(
    [string] $WorkDir = $PSScriptRoot,
    [string] $LogDir,
    [ValidateSet('Auto', 'Local', 'Online')][string] $Source = 'Online',
    [string] $DownloadDir,
    [ValidateRange(1, 86400)][int] $DownloadTimeoutSeconds = 1800,
    [switch] $DownloadOnly,
    [switch] $KeepDownloads,
    [switch] $NoProvision,
    [switch] $SkipWinget,
    [switch] $PauseAtEnd
)

# Everything runs inside a private in-memory module so that, when invoked via irm | iex (which
# executes in the caller's scope), no functions, variables, StrictMode or preference changes leak
# into the user's session, and `exit` never closes their PowerShell window.
$StoreLtscInvocation = @{
    Params     = @{
        WorkDir = $WorkDir; LogDir = $LogDir; Source = $Source; DownloadDir = $DownloadDir
        DownloadTimeoutSeconds = $DownloadTimeoutSeconds
        DownloadOnly = [bool]$DownloadOnly; KeepDownloads = [bool]$KeepDownloads
        NoProvision = [bool]$NoProvision; SkipWinget = [bool]$SkipWinget
    }
    Bound      = @{}
    ScriptPath = $OriginalScriptPath
    ScriptText = $OriginalScriptText
}
foreach ($kv in $PSBoundParameters.GetEnumerator()) { $StoreLtscInvocation.Bound[$kv.Key] = $kv.Value }

$StoreLtscExitCode = New-Module -Name 'Store-LTSC' -ArgumentList $StoreLtscInvocation -ReturnResult -ScriptBlock {
param($Invocation)
Export-ModuleMember -Function @()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Appx/DISM progress bars slow down and clutter non-interactive runs

foreach ($kv in $Invocation.Params.GetEnumerator()) { Set-Variable -Name $kv.Key -Value $kv.Value }
$script:BoundParams = $Invocation.Bound
$script:ScriptPath = $Invocation.ScriptPath
$script:ScriptText = $Invocation.ScriptText

$script:LogFile = $null
$script:FailCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:SupersededFrameworks = New-Object System.Collections.Generic.List[string]
$script:ProvisionedCache = $null
$script:IsOnline = $false
$script:LicenseDirs = @()
$script:CleanupDir = $null
$script:CleanupToken = $null
$script:OnlineFrameworkNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# Package family names of everything this script installs (looked up in the Store catalog for online mode)
$script:StoreFamily = 'Microsoft.WindowsStore_8wekyb3d8bbwe'
$script:OptionalFamilies = @('Microsoft.StorePurchaseApp_8wekyb3d8bbwe', 'Microsoft.XboxIdentityProvider_8wekyb3d8bbwe')
$script:WingetFamily = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'

# region Helpers
function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsSystemAccount {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
        catch { Write-Host "[log write failed: $($_.Exception.Message)]" }
    }
    Write-Host $line
}

function Add-Failure {
    # Counts a partial failure and keeps its description for the summary.
    param([Parameter(Mandatory)][string] $Message)
    $script:FailCount++
    $script:Failures.Add($Message)
}

function Format-ErrorText {
    # Deployment errors span several lines; keep each log entry on one line.
    param([AllowNull()][AllowEmptyString()][string] $Text)
    return ($Text -replace '\s+', ' ').Trim()
}

function Complete-Run {
    # Cleanup + final log line; returns the exit code (use as: return (Complete-Run 5 'reason')).
    param([Parameter(Mandatory)][int] $Code, [string] $Reason)
    if ($script:CleanupDir -and (Test-Path -LiteralPath $script:CleanupDir)) {
        try {
            $resolved = [IO.Path]::GetFullPath($script:CleanupDir)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            $marker = Join-Path $resolved '.store-ltsc-owner'
            if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($resolved) -notmatch '^StoreInstall-Packages-[a-f0-9]{32}$' -or
                -not $script:CleanupToken -or -not (Test-Path -LiteralPath $marker -PathType Leaf) -or
                (Get-Content -LiteralPath $marker -Raw).Trim() -ne $script:CleanupToken -or
                ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Refusing cleanup because the temporary directory ownership check failed.'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
            Write-Log "Removed downloaded packages: $script:CleanupDir"
        }
        catch { Write-Log "Could not remove ${script:CleanupDir}: $($_.Exception.Message)" 'WARN' }
    }
    Write-Log ('==== finished (exit {0}{1}) ====' -f $Code, $(if ($Reason) { " - $Reason" }))
    return $Code
}

function Test-CanPromptForElevation {
    if (-not [Environment]::UserInteractive -or (Test-IsSystemAccount)) { return $false }
    # Started with -NonInteractive (CI, the .cmd wrapper, scheduled tasks): never pop up UAC.
    return -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' })
}

function Invoke-Relaunch {
    # Re-runs this script in 64-bit Windows PowerShell, optionally elevated via UAC; returns its exit code.
    param([switch] $Elevate)
    $sysDir = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $psExe = Join-Path $env:SystemRoot "$sysDir\WindowsPowerShell\v1.0\powershell.exe"
    $bound = @{} + $script:BoundParams
    $null = $bound.Remove('PauseAtEnd')

    $tempDir = $null
    try {
        # Use the executing revision, including when a local file changes during this run.
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('Store-LTSC-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tempDir
        $file = Join-Path $tempDir 'install.ps1'
        if (-not $script:ScriptText) { throw 'The executing script content is unavailable for relaunch.' }
        [IO.File]::WriteAllText($file, $script:ScriptText, [Text.UTF8Encoding]::new($true))
        # Pass resolved paths: the child can start elsewhere (elevated processes start in System32).
        $bound['WorkDir'] = $WorkDir
        if ($bound.ContainsKey('LogDir')) { $bound['LogDir'] = $LogDir }
        if ($bound.ContainsKey('DownloadDir')) { $bound['DownloadDir'] = $DownloadDir }
        if (-not $bound.ContainsKey('LogDir')) { $bound['LogDir'] = Join-Path ([IO.Path]::GetTempPath()) 'StoreInstall-Logs' }

        foreach ($key in @($bound.Keys)) {
            if ($bound[$key] -is [System.Management.Automation.SwitchParameter]) { $bound[$key] = [bool]$bound[$key] }
        }
        if ($Elevate) { $bound['PauseAtEnd'] = $true }
        # Encode a parameter splat instead of constructing native command-line quoting.
        $parameterData = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize($bound)))
        $bootstrap = '$parameters = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + $parameterData + '''))); & ''' + $file.Replace("'", "''") + ''' @parameters 6>&1; exit $LASTEXITCODE'
        $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-InputFormat', 'Text', '-OutputFormat', 'Text')
        if (-not $Elevate) { $argList += '-NonInteractive' }
        $argList += '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

        if ($Elevate) {
            $cmdLine = $argList -join ' '
            Write-Host 'Requesting administrator rights (UAC). The install continues in a new window...'
            $proc = Start-Process -FilePath $psExe -ArgumentList $cmdLine -Verb RunAs -Wait -PassThru
            Write-Host "Elevated run finished with exit code $($proc.ExitCode)."
            return $proc.ExitCode
        }
        Write-Host "Re-launching in 64-bit Windows PowerShell: $psExe"
        & $psExe @argList | Out-Host   # show the child's output instead of returning it as pipeline data
        return $LASTEXITCODE
    }
    finally {
        if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-UserPath {
    # Resolve relative paths against the PowerShell location, not the process directory .NET uses.
    param([AllowNull()][AllowEmptyString()][string] $Path)
    if (-not $Path) { return $Path }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-OsArch {
    # The machine-wide value reflects the native arch even from WOW64/x64-emulated processes.
    $native = $null
    try {
        $native = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
    }
    catch { }
    if (-not $native) {
        $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    switch ($native) {
        'ARM64' { return 'arm64' }
        'x86'   { return 'x86' }
        default { return 'x64' }
    }
}

function Get-PackageIdentity {
    # Parses Name_Version_Arch_ResourceId_PublisherId (e.g. Microsoft.VCLibs.140.00_14.0.33519.0_x64__8wekyb3d8bbwe).
    # Falls back to a best-effort name/arch for non-standard file names (e.g. Microsoft.VCLibs.x64.14.00.Desktop.appx).
    param([Parameter(Mandatory)][string] $FileName)
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)

    if ($base -match '^(?<name>[^_]+)_(?<ver>\d+(?:\.\d+){1,3})_(?<arch>[^_]*)_(?<res>[^_]*)_(?<pub>[0-9a-z]{13})$') {
        $arch = $Matches['arch'].ToLowerInvariant()
        if (-not $arch) { $arch = 'neutral' }
        return [pscustomobject]@{
            Name    = $Matches['name']
            Version = [version]$Matches['ver']
            Arch    = $arch
            Family  = '{0}_{1}' -f $Matches['name'], $Matches['pub']
        }
    }

    $arch = $null
    foreach ($a in 'arm64', 'x64', 'x86', 'arm', 'neutral') {
        if ($base -match "(^|[._-])$a([._-]|$)") { $arch = $a; break }
    }
    return [pscustomobject]@{
        Name    = ($base -split '_')[0]
        Version = $null
        Arch    = $arch
        Family  = $null
    }
}

function Read-PackageManifest {
    param([Parameter(Mandatory)][IO.Stream] $Stream)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Stream, $settings)
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($reader)
        return ,$xml
    }
    finally { $reader.Dispose() }
}

function Get-PublisherId {
    param([Parameter(Mandatory)][string] $Publisher)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($Publisher)) } finally { $sha.Dispose() }
    $alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    $bits = ($hash[0..7] | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    $bits += '0'
    $result = ''
    for ($i = 0; $i -lt 65; $i += 5) { $result += $alphabet[[Convert]::ToInt32($bits.Substring($i, 5), 2)] }
    return $result
}

function Get-PackageMetadata {
    # Read identities from package contents so renamed offline files remain usable.
    param([Parameter(Mandatory)][string] $Path, [string] $OsArch, [int] $Build, [int] $Revision = 0)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $manifest = $zip.GetEntry('AppxManifest.xml')
        if ($manifest) {
            $stream = $manifest.Open()
            try { $xml = Read-PackageManifest $stream } finally { $stream.Dispose() }
            $identity = $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Identity"]')
            if (-not $identity) { throw "Package identity missing in '$Path'." }
            $arch = $identity.GetAttribute('ProcessorArchitecture')
            if (-not $arch) { $arch = 'neutral' }
            $deps = @($xml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="PackageDependency"]') | ForEach-Object {
                [pscustomobject]@{ Name = $_.GetAttribute('Name'); Publisher = $_.GetAttribute('Publisher'); MinVersion = $(if ($_.GetAttribute('MinVersion')) { [version]$_.GetAttribute('MinVersion') } else { [version]'0.0.0.0' }); Arch = $arch }
            })
            $framework = $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Properties"]/*[local-name()="Framework"]')
            $targets = @($xml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="TargetDeviceFamily"]') | Where-Object { $_.GetAttribute('Name') -in @('Windows.Universal', 'Windows.Desktop') })
            $supported = $targets.Count -eq 0 -or @($targets | Where-Object { -not $_.GetAttribute('MinVersion') -or [version]$_.GetAttribute('MinVersion') -le [version]("10.0.$Build.$Revision") }).Count -gt 0
            return [pscustomobject]@{ Name = $identity.GetAttribute('Name'); Version = [version]$identity.GetAttribute('Version'); Arch = $arch; Family = ($identity.GetAttribute('Name') + '_' + (Get-PublisherId $identity.GetAttribute('Publisher'))); Publisher = $identity.GetAttribute('Publisher'); IsFramework = ($framework -and $framework.InnerText -eq 'true'); Dependencies = $deps; Supported = $supported }
        }
        $manifest = $zip.GetEntry('AppxMetadata/AppxBundleManifest.xml')
        if (-not $manifest) { throw "No Appx package or bundle manifest in '$Path'." }
        $stream = $manifest.Open()
        try { $xml = Read-PackageManifest $stream } finally { $stream.Dispose() }
        $identity = $xml.SelectSingleNode('/*[local-name()="Bundle"]/*[local-name()="Identity"]')
        if (-not $identity) { throw "Bundle identity missing in '$Path'." }
        $payloads = @($xml.SelectNodes('/*[local-name()="Bundle"]/*[local-name()="Packages"]/*[local-name()="Package"]') | Where-Object { $_.GetAttribute('Type') -eq 'application' -and (Get-ArchRank -Arch $_.GetAttribute('Architecture') -OsArch $OsArch -Build $Build) -gt 0 })
        $best = $payloads | Sort-Object @{ Expression = { Get-ArchRank -Arch $_.GetAttribute('Architecture') -OsArch $OsArch -Build $Build }; Descending = $true } | Select-Object -First 1
        $deps = @()
        $supported = $true
        if ($best) {
            $entry = $zip.GetEntry($best.GetAttribute('FileName'))
            if (-not $entry) { throw "Bundle payload '$($best.GetAttribute('FileName'))' missing in '$Path'." }
            $memory = New-Object IO.MemoryStream
            $stream = $entry.Open()
            try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
            $memory.Position = 0
            $inner = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Read)
            try {
                $entry = $inner.GetEntry('AppxManifest.xml')
                if (-not $entry) { throw "Bundle payload manifest missing in '$Path'." }
                $stream = $entry.Open()
                try { $payloadXml = Read-PackageManifest $stream } finally { $stream.Dispose() }
                $targets = @($payloadXml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="TargetDeviceFamily"]') | Where-Object { $_.GetAttribute('Name') -in @('Windows.Universal', 'Windows.Desktop') })
                # Check the preferred payload. Do not assume Windows will fall back to an emulated payload.
                $supported = $targets.Count -eq 0 -or @($targets | Where-Object { -not $_.GetAttribute('MinVersion') -or [version]$_.GetAttribute('MinVersion') -le [version]("10.0.$Build.$Revision") }).Count -gt 0
                $deps = @($payloadXml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="PackageDependency"]') | ForEach-Object {
                    [pscustomobject]@{ Name = $_.GetAttribute('Name'); Publisher = $_.GetAttribute('Publisher'); MinVersion = $(if ($_.GetAttribute('MinVersion')) { [version]$_.GetAttribute('MinVersion') } else { [version]'0.0.0.0' }); Arch = $best.GetAttribute('Architecture') }
                })
            }
            finally { $inner.Dispose(); $memory.Dispose() }
        }
        return [pscustomobject]@{ Name = $identity.GetAttribute('Name'); Version = [version]$identity.GetAttribute('Version'); Arch = $(if ($best) { $best.GetAttribute('Architecture') } else { 'unsupported' }); Family = ($identity.GetAttribute('Name') + '_' + (Get-PublisherId $identity.GetAttribute('Publisher'))); Publisher = $identity.GetAttribute('Publisher'); IsFramework = $false; Dependencies = $deps; Supported = $supported }
    }
    finally { $zip.Dispose() }
}

function Get-PackageDependencyState {
    # Splits a package's dependencies into supplied frameworks it needs and dependencies nothing satisfies.
    param([Parameter(Mandatory)] $Package, [object[]] $Frameworks)
    $required = @()
    $missing = @()
    foreach ($dep in $Package.Identity.Dependencies) {
        $supplied = @($Frameworks | Where-Object { $_.Identity.Name -eq $dep.Name -and $_.Identity.Version -ge $dep.MinVersion -and (-not $dep.Publisher -or $_.Identity.Publisher -eq $dep.Publisher) -and ($_.Identity.Arch -eq 'neutral' -or $_.Identity.Arch -eq $dep.Arch) })
        if ($supplied.Count -gt 0) { $required += $supplied; continue }
        if ($script:DoProvision) {
            $expectedFamily = if ($dep.Publisher) { $dep.Name + '_' + (Get-PublisherId $dep.Publisher) } else { $null }
            $installed = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object {
                $provisionedIdentity = Get-PackageIdentity -FileName ($_.PackageName + '.appx')
                $provisionedIdentity.Name -eq $dep.Name -and $provisionedIdentity.Version -ge $dep.MinVersion -and (-not $expectedFamily -or $provisionedIdentity.Family -eq $expectedFamily) -and ($provisionedIdentity.Arch -eq 'neutral' -or $provisionedIdentity.Arch -eq $dep.Arch)
            })
        }
        else { $installed = @(Get-AppxPackage -Name $dep.Name -ErrorAction SilentlyContinue | Where-Object { [version]$_.Version -ge $dep.MinVersion -and (-not $dep.Publisher -or $_.Publisher -eq $dep.Publisher) -and ($_.Architecture.ToString() -eq 'Neutral' -or $_.Architecture.ToString() -eq $dep.Arch) }) }
        if ($installed.Count -eq 0) { $missing += $dep }
    }
    return [pscustomobject]@{ Required = $required; Missing = $missing }
}

function Format-MissingDependency {
    param([Parameter(Mandatory)] $Dependency, [Parameter(Mandatory)] $Package)
    return "Missing dependency '$($Dependency.Name)' version $($Dependency.MinVersion) or newer for '$($Package.Identity.Name)' ($($Dependency.Arch))."
}

function Test-OptionalAppDependency {
    # Returns $true when an optional app's dependencies are satisfied; otherwise logs them and counts a partial failure.
    param([Parameter(Mandatory)] $Package, [object[]] $Frameworks)
    $missing = @((Get-PackageDependencyState -Package $Package -Frameworks $Frameworks).Missing)
    if ($missing.Count -eq 0) { return $true }
    foreach ($dep in $missing) { Write-Log "Skipping $($Package.File.Name): $(Format-MissingDependency $dep $Package)" 'WARN' }
    Add-Failure "Skipped $($Package.Identity.Name): missing dependencies"
    return $false
}

function Get-ProvisionedIdentity {
    # Provisioned package identities, read once; -Refresh re-reads the image after provisioning changes.
    param([switch] $Refresh)
    if ($Refresh -or $null -eq $script:ProvisionedCache) {
        $script:ProvisionedCache = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { Get-PackageIdentity -FileName ($_.PackageName + '.appx') })
    }
    return $script:ProvisionedCache
}

function Find-InstalledFramework {
    # Packages with the same framework identity (name, publisher, architecture) at version >= the given package.
    param(
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)][ValidateSet('Provisioned', 'CurrentUser', 'AllUsers')][string] $Scope
    )
    if ($Scope -eq 'Provisioned') {
        return @(Get-ProvisionedIdentity | Where-Object { $_.Name -eq $Identity.Name -and $_.Family -eq $Identity.Family -and $_.Arch -eq $Identity.Arch -and $_.Version -ge $Identity.Version } |
            Sort-Object Version -Descending)
    }
    $packages = if ($Scope -eq 'AllUsers') { Get-AppxPackage -AllUsers -Name $Identity.Name -ErrorAction SilentlyContinue } else { Get-AppxPackage -Name $Identity.Name -ErrorAction SilentlyContinue }
    return @($packages | Where-Object { $_.Publisher -eq $Identity.Publisher -and $_.Architecture.ToString() -eq $Identity.Arch -and [version]$_.Version -ge $Identity.Version } |
        Sort-Object { [version]$_.Version } -Descending)
}

function Test-InstallResult {
    # Confirms the result with Windows instead of trusting cmdlet success: current-user registration and, when
    # provisioning, that every app and each of its dependencies is provisioned for new users. Returns $false if the Store is not registered.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Applications)
    $storeRegistered = $true
    if (-not $script:IsSystem) {
        foreach ($app in $Applications) {
            $registered = @(Get-AppxPackage -Name $app.Identity.Name -ErrorAction SilentlyContinue | Where-Object { [string]$_.Status -eq 'Ok' })
            if ($registered.Count -gt 0) {
                Write-Log "Verified (current user): $($app.Identity.Name) $($registered[0].Version), status Ok"
                continue
            }
            Write-Log "Not registered for the current user after installation: $($app.Identity.Name)" 'ERROR'
            Add-Failure "$($app.Identity.Name) is not registered for the current user"
            if ($app.Identity.Name -eq 'Microsoft.WindowsStore') { $storeRegistered = $false }
        }
    }
    if (-not $script:DoProvision) { return $storeRegistered }

    $provisioned = @(Get-ProvisionedIdentity -Refresh)
    $unmet = 0
    foreach ($app in $Applications) {
        if (-not ($provisioned | Where-Object { $_.Name -eq $app.Identity.Name -and $_.Family -eq $app.Identity.Family })) {
            Write-Log "Not provisioned for new users after installation: $($app.Identity.Name)" 'ERROR'
            Add-Failure "$($app.Identity.Name) is not provisioned for new users"
            continue
        }
        foreach ($dep in $app.Identity.Dependencies) {
            $expectedFamily = if ($dep.Publisher) { $dep.Name + '_' + (Get-PublisherId $dep.Publisher) } else { $null }
            $match = @($provisioned | Where-Object { $_.Name -eq $dep.Name -and (-not $expectedFamily -or $_.Family -eq $expectedFamily) -and ($_.Arch -eq 'neutral' -or $_.Arch -eq $dep.Arch) -and $_.Version -ge $dep.MinVersion })
            if ($match.Count -gt 0) { continue }
            $unmet++
            Write-Log "New users: $($app.Identity.Name) needs $($dep.Name) $($dep.MinVersion) or newer ($($dep.Arch)), which is not provisioned." 'ERROR'
            Add-Failure "$($dep.Name) ($($dep.Arch)) for $($app.Identity.Name) is not provisioned for new users"
        }
    }
    if ($unmet -eq 0) {
        Write-Log "Verified (new users): $(@($Applications).Count) app(s) provisioned with all dependencies"
        foreach ($name in $script:SupersededFrameworks) {
            Write-Log "Not provisioning ${name} is harmless: newer provisioned frameworks satisfy every app dependency."
        }
    }
    return $storeRegistered
}

function Get-DependencyInstallOrder {
    param([object[]] $Frameworks, [object[]] $Applications)
    $ordered = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($pkg in $Frameworks) { $pending.Add($pkg) }
    $allPackages = @($Frameworks) + @($Applications)
    $edges = @{}
    foreach ($pkg in $allPackages) {
        $state = Get-PackageDependencyState -Package $pkg -Frameworks $Frameworks
        if (@($state.Missing).Count -gt 0) { throw "$(Format-MissingDependency @($state.Missing)[0] $pkg) Add the matching framework package to the package directory." }
        $edges[$pkg.File.FullName] = @($state.Required)
    }
    while ($pending.Count -gt 0) {
        $next = @($pending | Where-Object { $blocked = $false; foreach ($dependency in $edges[$_.File.FullName]) { if ($pending.Contains($dependency)) { $blocked = $true } }; -not $blocked } | Sort-Object { $_.File.Name } | Select-Object -First 1)
        if ($next.Count -eq 0) { throw "Framework dependency cycle detected: $(($pending | ForEach-Object { $_.Identity.Name }) -join ', ')." }
        $ordered.Add($next[0]); $null = $pending.Remove($next[0])
    }
    return $ordered.ToArray()
}

function Select-RequiredFramework {
    # Keeps the frameworks the apps declare, directly or through another kept framework.
    param([object[]] $Frameworks, [object[]] $Applications)
    $required = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.Queue[object]
    foreach ($app in $Applications) { $pending.Enqueue($app) }
    while ($pending.Count -gt 0) {
        foreach ($fw in @((Get-PackageDependencyState -Package $pending.Dequeue() -Frameworks $Frameworks).Required)) {
            if (-not $required.Contains($fw)) { $required.Add($fw); $pending.Enqueue($fw) }
        }
    }
    foreach ($fw in $Frameworks) {
        if (-not $required.Contains($fw)) { Write-Log "Skipping framework no app declares: $($fw.File.Name)" }
    }
    return $required.ToArray()
}

function Find-License {
    param(
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)] $Identity
    )
    # Package folder first, then WorkDir (downloaded packages can still use license XMLs shipped next to the script)
    $dirs = @([IO.Path]::GetDirectoryName($PackagePath)) + @($script:LicenseDirs) | Select-Object -Unique

    foreach ($dir in $dirs) {
        if ($Identity.Family) {
            $exact = Join-Path $dir ($Identity.Family + '.xml')
            if (Test-Path -LiteralPath $exact -PathType Leaf) { return $exact }
        }

        # Require "<Name>_" or "<Name>.xml" so e.g. Microsoft.VCLibs.140.00 does not pick up the UWPDesktop license.
        $cand = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.xml' -and ($_.Name -like ($Identity.Name + '_*') -or $_.Name -eq ($Identity.Name + '.xml')) } |
            Sort-Object Name |
            Select-Object -First 1
        if ($cand) { return $cand.FullName }
    }
    return $null
}

function Test-IsFrameworkPackage {
    param([Parameter(Mandatory)][string] $Name)
    if ($script:OnlineFrameworkNames.Contains($Name)) { return $true }   # flagged IsAppxFramework by the Store service
    return (
        $Name -like 'Microsoft.VCLibs.*' -or
        $Name -like 'Microsoft.UI.Xaml.*' -or
        $Name -like 'Microsoft.NET.Native.*' -or
        $Name -like 'Microsoft.WindowsAppRuntime.*'
    )
}

function Get-ArchRank {
    # 2 = native/neutral, 1 = supported side-by-side, 0 = skip
    param(
        [AllowNull()][string] $Arch,
        [Parameter(Mandatory)][string] $OsArch,
        [Parameter(Mandatory)][int] $Build
    )
    if ($Arch -eq 'neutral' -or $Arch -eq $OsArch) { return 2 }
    switch ($OsArch) {
        'x64' {
            if ($Arch -eq 'x86') { return 1 }
        }
        'arm64' {
            if ($Arch -eq 'x86') { return 1 }
            if ($Arch -eq 'x64' -and $Build -ge 22000) { return 1 }   # x64 emulation: Windows 11+
            if ($Arch -eq 'arm' -and $Build -lt 26100) { return 1 }   # ARM32 removed in Windows 11 24H2
        }
    }
    return 0
}

function Select-NewerPackage {
    param($Current, [Parameter(Mandatory)] $Candidate)
    if (-not $Current) { return $Candidate }
    $curVer = if ($Current.Identity.Version) { $Current.Identity.Version } else { [version]'0.0' }
    $candVer = if ($Candidate.Identity.Version) { $Candidate.Identity.Version } else { [version]'0.0' }
    $keep, $drop = if ($candVer -gt $curVer -or ($candVer -eq $curVer -and $Candidate.Rank -gt $Current.Rank)) { $Candidate, $Current } else { $Current, $Candidate }
    Write-Log "Multiple packages for $($keep.Identity.Name); using $($keep.File.Name), ignoring $($drop.File.Name)" 'WARN'
    return $keep
}

function Install-OnePackage {
    param(
        [Parameter(Mandatory)] $Package,
        [switch] $IsFramework
    )

    $path = $Package.File.FullName
    $name = $Package.File.Name
    $ok = $true

    # Windows cannot deploy an older copy of a framework that is already present; skip instead of failing.
    $provisioned = @(if ($script:DoProvision -and $IsFramework) { Find-InstalledFramework -Identity $Package.Identity -Scope Provisioned })
    if ($provisioned.Count -gt 0) {
        Write-Log "Already provisioned: $name (version $($provisioned[0].Version) present)"
    }
    elseif ($script:DoProvision) {
        $license = $null
        if (-not $IsFramework) {
            $license = Find-License -PackagePath $path -Identity $Package.Identity
            if ($license) {
                Write-Log "License for ${name}: $([IO.Path]::GetFileName($license))"
            }
            else {
                # Expected for downloaded packages; a local folder may have been meant to include one.
                Write-Log "No license XML for ${name}; provisioning with -SkipLicense" $(if ($script:IsOnline) { 'INFO' } else { 'WARN' })
            }
        }

        try {
            Write-Log "Provisioning: $name"
            if ($license) {
                $null = Add-AppxProvisionedPackage -Online -PackagePath $path -LicensePath $license -Regions 'all'
            }
            else {
                $null = Add-AppxProvisionedPackage -Online -PackagePath $path -SkipLicense
            }
            $script:ProvisionedCache = $null
            Write-Log "Provisioned OK: $name"
        }
        catch {
            $msg = Format-ErrorText $_.Exception.Message
            # DISM can reject an older framework when a newer one is already installed ("Element not found").
            # The post-install check decides whether new users still get every dependency.
            $newer = @(if ($IsFramework) { Find-InstalledFramework -Identity $Package.Identity -Scope AllUsers })
            if ($newer.Count -gt 0) {
                Write-Log "Provision not applied: $name :: $msg" 'WARN'
                Write-Log "Version $($newer[0].Version) of this framework is already installed on this machine; new-user dependencies are verified after installation." 'WARN'
                $script:SupersededFrameworks.Add($name)
            }
            else {
                Write-Log "Provision FAILED: $name :: $msg" 'ERROR'
                $ok = $false
                Add-Failure "Provisioning failed: $name"
            }
        }
    }

    if ($script:IsSystem) {
        # Add-AppxPackage cannot register packages for the SYSTEM account; provisioning covers all users.
        Write-Log "Per-user install skipped (running as SYSTEM): $name"
        return $ok
    }

    $registered = @(if ($IsFramework) { Find-InstalledFramework -Identity $Package.Identity -Scope CurrentUser })
    if ($registered.Count -gt 0) {
        Write-Log "Already registered (current user): $name (version $($registered[0].Version) present)"
        return $ok
    }

    try {
        Write-Log "Installing (current user): $name"
        $null = Add-AppxPackage -Path $path -ForceApplicationShutdown -ForceUpdateFromAnyVersion
        Write-Log "Install OK: $name"
    }
    catch {
        $msg = Format-ErrorText $_.Exception.Message
        # Non-fatal: 0x80073D06 = higher version already installed, 0x80073CFB = same identity already installed
        if ($msg -match '0x80073D06|0x80073CFB|higher version|already installed') {
            Write-Log "Install skipped/non-fatal: $name :: $msg" 'WARN'
        }
        else {
            Write-Log "Install FAILED: $name :: $msg" 'ERROR'
            $ok = $false
            Add-Failure "Install failed (current user): $name"
        }
    }

    return $ok
}
# endregion

# region Online download (Microsoft Store delivery service)
$script:Fe3Url = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$script:WuNs = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'

function Initialize-Network {
    # TLS 1.2 for older .NET defaults; use the system proxy with the current user's credentials.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([Net.WebRequest]::DefaultWebProxy) {
        [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $What,
        [int] $Attempts = 3
    )
    for ($i = 1; ; $i++) {
        try { return (& $Action) }
        catch {
            if ($i -ge $Attempts) { throw "$What failed after $Attempts attempts: $($_.Exception.Message)" }
            Write-Log "$What failed (attempt $i/$Attempts): $($_.Exception.Message); retrying" 'WARN'
            Start-Sleep -Seconds (5 * $i)
        }
    }
}

function Get-WuCategoryId {
    param([Parameter(Mandatory)][string] $PackageFamilyName)
    $uri = 'https://displaycatalog.mp.microsoft.com/v7.0/products/lookup?alternateId=PackageFamilyName' +
        "&Value=$PackageFamilyName&market=US&languages=en-US,neutral&fieldsTemplate=Details"
    $resp = Invoke-WithRetry -What "Catalog lookup for $PackageFamilyName" -Action {
        Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 60
    }
    $product = @($resp.Products) | Select-Object -First 1
    if (-not $product) { throw "Store catalog has no product for $PackageFamilyName" }
    $fd = $product.DisplaySkuAvailabilities[0].Sku.Properties.FulfillmentData
    if ($fd -is [string]) { $fd = $fd | ConvertFrom-Json }
    if (-not $fd.WuCategoryId) { throw "No WuCategoryId for $PackageFamilyName" }
    return [string]$fd.WuCategoryId
}

function Invoke-Fe3 {
    param(
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][string] $Body,
        [switch] $Secured
    )
    $to = if ($Secured) { "$script:Fe3Url/secured" } else { $script:Fe3Url }
    $now = [DateTime]::UtcNow
    $envelope = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<a:Action s:mustUnderstand="1">$script:WuNs/$Action</a:Action>
<a:MessageID>urn:uuid:$([guid]::NewGuid())</a:MessageID>
<a:To s:mustUnderstand="1">$to</a:To>
<o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
<Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><Created>$($now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))</Created><Expires>$($now.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))</Expires></Timestamp>
<wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization"><TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><User /></TicketType></wuws:WindowsUpdateTicketsToken>
</o:Security>
</s:Header>
<s:Body>$Body</s:Body>
</s:Envelope>
"@
    $bytes = [Text.Encoding]::UTF8.GetBytes($envelope)
    $resp = Invoke-WithRetry -What "FE3 $Action" -Action {
        Invoke-WebRequest -Uri $to -Method Post -Body $bytes -ContentType 'application/soap+xml; charset=utf-8' -UseBasicParsing -TimeoutSec 120
    }
    return [xml]$resp.Content
}

function Get-Fe3DeviceAttributes {
    param([Parameter(Mandatory)][string] $OsArch, [Parameter(Mandatory)][int] $Build)
    $arch = @{ x64 = 'AMD64'; arm64 = 'ARM64'; x86 = 'X86' }[$OsArch]
    return "BranchReadinessLevel=CB;CurrentBranch=rs_prerelease;FlightRing=Retail;AttrDataVer=21;InstallLanguage=en-US;OSUILocale=en-US;" +
        "InstallationType=Client;FlightingBranchName=external;OSSkuId=48;FlightContent=Branch;App=WU;AppVer=10.0.$Build.1;" +
        "OSArchitecture=$arch;UpdateManagementGroup=2;IsFlightingEnabled=0;IsDeviceRetailDemo=0;TelemetryLevel=3;" +
        "OSVersion=10.0.$Build.1;DeviceFamily=Windows.Desktop;"
}

function Get-Fe3Cookie {
    $body = "<GetCookie xmlns=`"$script:WuNs`"><oldCookie></oldCookie><lastChange>2015-10-21T17:01:07.1472913Z</lastChange>" +
        "<currentTime>$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))</currentTime><protocolVersion>1.40</protocolVersion></GetCookie>"
    $xml = Invoke-Fe3 -Action 'GetCookie' -Body $body
    $cookie = $xml.GetElementsByTagName('EncryptedData') | Select-Object -First 1
    if (-not $cookie) { throw 'FE3 GetCookie returned no cookie' }
    return $cookie.InnerText
}

function Get-Fe3PackageList {
    # Returns every downloadable package (main app + all framework dependencies) the service lists for a category.
    param(
        [Parameter(Mandatory)][string] $CategoryId,
        [Parameter(Mandatory)][string] $Cookie,
        [Parameter(Mandatory)][string] $DeviceAttributes
    )
    # Baseline "installed" update IDs the service expects from a Windows client
    $nonLeaf = 1, 2, 3, 11, 19, 544, 549, 2359974, 2359977, 5169044, 8788830, 23110993, 23110994, 54341900, 54343656,
        59830006, 59830007, 59830008, 60484010, 62450018, 62450019, 62450020, 66027979, 66053150, 97657898, 98822896,
        98959022, 98959023, 98959024, 98959025, 98959026, 104433538, 104900364, 105489019, 117765322, 129905029,
        130040031, 132387090, 132393049, 133399034, 138537048, 140377312, 143747671, 158941041, 158941042, 158941043,
        158941044, 159123858, 159130928, 164836897, 164847386, 164848327, 164852241, 164852246, 164852252, 164852253
    $body = "<SyncUpdates xmlns=`"$script:WuNs`"><cookie><Expiration>2045-03-11T02:02:48Z</Expiration><EncryptedData>$Cookie</EncryptedData></cookie>" +
        '<parameters><ExpressQuery>false</ExpressQuery><InstalledNonLeafUpdateIDs>' + (($nonLeaf | ForEach-Object { "<int>$_</int>" }) -join '') +
        '</InstalledNonLeafUpdateIDs><OtherCachedUpdateIDs></OtherCachedUpdateIDs><SkipSoftwareSync>false</SkipSoftwareSync>' +
        '<NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>' +
        "<FilterAppCategoryIds><CategoryIdentifier><Id>$CategoryId</Id></CategoryIdentifier></FilterAppCategoryIds>" +
        '<TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled><AlsoPerformRegularSync>false</AlsoPerformRegularSync><ComputerSpec/>' +
        '<ExtendedUpdateInfoParameters><XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes>' +
        '<Locales><string>en-US</string><string>en</string></Locales></ExtendedUpdateInfoParameters>' +
        '<ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages><ProductsParameters><SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>' +
        "<DeviceAttributes>$DeviceAttributes</DeviceAttributes><CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes><Products/></ProductsParameters>" +
        '</parameters></SyncUpdates>'

    $xml = Invoke-Fe3 -Action 'SyncUpdates' -Body $body
    $ns = @{ w = $script:WuNs }

    $extended = @{}
    foreach ($u in (Select-Xml -Xml $xml -XPath '//w:ExtendedUpdateInfo/w:Updates/w:Update' -Namespace $ns)) {
        $extended[$u.Node.ID] = [xml]('<r>' + $u.Node.Xml + '</r>')
    }

    foreach ($u in (Select-Xml -Xml $xml -XPath '//w:NewUpdates/w:UpdateInfo' -Namespace $ns)) {
        $frag = [xml]('<r>' + $u.Node.Xml + '</r>')
        $props = $frag.SelectSingleNode('/r/Properties')
        $meta = $frag.SelectSingleNode('//AppxMetadata')
        # Only entries with a SecuredFragment have a downloadable file (the rest are detectoids/categories)
        if (-not $props -or -not $props.SelectSingleNode('SecuredFragment') -or -not $meta) { continue }
        $ext = $extended[$u.Node.ID]
        if (-not $ext) { continue }

        $moniker = $meta.GetAttribute('PackageMoniker')
        $file = $ext.SelectSingleNode("//File[@InstallerSpecificIdentifier='$moniker']")
        if (-not $file) { continue }
        $sha256 = $file.SelectSingleNode("AdditionalDigest[@Algorithm='SHA256']")
        $extension = [IO.Path]::GetExtension($file.GetAttribute('FileName')).ToLowerInvariant()
        $identity = $frag.SelectSingleNode('/r/UpdateIdentity')

        [pscustomobject]@{
            Moniker     = $moniker
            Extension   = $extension
            UpdateId    = $identity.GetAttribute('UpdateID')
            Revision    = $identity.GetAttribute('RevisionNumber')
            Size        = [long]$file.GetAttribute('Size')
            Sha1        = $file.GetAttribute('Digest')
            Sha256      = if ($sha256) { $sha256.InnerText } else { $null }
            IsFramework = $props.GetAttribute('IsAppxFramework') -eq 'true'
            # The Store's own release ordering; version numbers are not monotonic (Xbox Identity Provider 2017.x is older than 12.x)
            PackageRank = [int]('0' + $props.GetAttribute('PackageRank'))
            Identity    = Get-PackageIdentity -FileName ($moniker + $extension)
        }
    }
}

function Get-Fe3FileUrl {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)][string] $DeviceAttributes
    )
    $body = "<GetExtendedUpdateInfo2 xmlns=`"$script:WuNs`"><updateIDs><UpdateIdentity><UpdateID>$($Package.UpdateId)</UpdateID>" +
        "<RevisionNumber>$($Package.Revision)</RevisionNumber></UpdateIdentity></updateIDs><infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>" +
        "<XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType></infoTypes><deviceAttributes>$DeviceAttributes</deviceAttributes></GetExtendedUpdateInfo2>"
    $xml = Invoke-Fe3 -Action 'GetExtendedUpdateInfo2' -Body $body -Secured
    # The response also lists the blockmap; pick the location whose digest matches the package file.
    foreach ($loc in $xml.GetElementsByTagName('FileLocation')) {
        $digest = $loc.GetElementsByTagName('FileDigest') | Select-Object -First 1
        $url = $loc.GetElementsByTagName('Url') | Select-Object -First 1
        if ($digest -and $url -and $digest.InnerText -eq $Package.Sha1) { return $url.InnerText }
    }
    throw "No download URL returned for $($Package.Moniker)"
}

function Test-PackageFile {
    # Integrity (hash published by the service over HTTPS) + authenticity (Microsoft signature).
    # The signature check needs the real .appx/.msix* extension, so -SkipSignature is used for .part files.
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Package, [switch] $SkipSignature)
    if ((Get-Item -LiteralPath $Path).Length -ne $Package.Size) { return 'size mismatch' }
    $algo, $b64 = if ($Package.Sha256) { 'SHA256', $Package.Sha256 } else { 'SHA1', $Package.Sha1 }
    $expected = [BitConverter]::ToString([Convert]::FromBase64String($b64)) -replace '-', ''
    if ((Get-FileHash -LiteralPath $Path -Algorithm $algo).Hash -ne $expected) { return "$algo mismatch" }
    if ($SkipSignature) { return $null }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
        return "signature not valid Microsoft ($($sig.Status): $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject }))"
    }
    return $null
}

function Save-PackageDownload {
    param([string] $Url, [string] $Path, [int] $TimeoutSeconds = 1800)
    # Cancellation aborts the underlying request before the client and temporary file are released.
    $client = New-Object Net.WebClient
    try {
        $task = $client.DownloadFileTaskAsync([uri]$Url, $Path)
        if (-not $task.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            $client.CancelAsync()
            try { $task.GetAwaiter().GetResult() } catch { }
            throw "Download exceeded the $TimeoutSeconds second time limit"
        }
        $task.GetAwaiter().GetResult()
    }
    finally { $client.CancelAsync(); $client.Dispose() }
}

function Test-OfflineManifest {
    param([string] $Directory, [string] $OsArch, [int] $Build, [string[]] $Families)
    $manifestPath = Join-Path $Directory 'store-packages.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1) { throw 'Unsupported offline package manifest schema' }
    if ($manifest.OsArch -ne $OsArch) { throw "Offline packages target $($manifest.OsArch), not $OsArch" }
    foreach ($family in $Families) {
        if (@($manifest.RequestedFamilies) -notcontains $family) { throw "Offline manifest does not include requested app $family" }
        if (@($manifest.MissingFamilies) -contains $family) { throw "Offline package manifest records a missing requested app: $family" }
    }
    $seen = @{}
    $files = foreach ($entry in $manifest.Files) {
        $name = [string]$entry.Name
        if (-not $name -or $name -match '[\\/:*?"<>|]' -or $name -eq '.' -or $name -eq '..' -or
            [IO.Path]::GetFileName($name) -ne $name -or $seen.ContainsKey($name) -or
            [IO.Path]::GetExtension($name) -notin @('.appx', '.msix', '.appxbundle', '.msixbundle')) {
            throw "Invalid or duplicate filename in offline manifest: $name"
        }
        $seen[$name] = $true
        $file = Get-Item -LiteralPath (Join-Path $Directory $name) -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Offline package must be a regular file: $name" }
        if ($entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $file.Length -ne $entry.Size -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $entry.Sha256) { throw "Offline package hash or size mismatch: $name" }
        # A user-editable manifest detects corruption. Microsoft signatures establish package authenticity.
        $sig = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
            throw "Offline package does not have a valid Microsoft signature: $name"
        }
        $file
    }
    if (@($files).Count -eq 0) { throw 'Offline package manifest has no files' }
    Write-Log "Verified offline manifest: $(@($files).Count) package(s), SHA256 and Microsoft signatures"
    $files
}

function Save-OnlinePackage {
    # Downloads one selected package, or reuses a verified copy, and returns its file.
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $DeviceAttributes
    )
    $p = $Package
    if (($p.Moniker + $p.Extension) -match '[\\/:*?"<>|]' -or $p.Moniker -match '^\.') { throw 'Service returned an unsafe package filename' }
    $target = Join-Path $Destination ($p.Moniker + $p.Extension)
    if ((Test-Path -LiteralPath $target -PathType Leaf) -and -not (Test-PackageFile -Path $target -Package $p)) {
        Write-Log "Already downloaded (verified): $([IO.Path]::GetFileName($target))"
        return (Get-Item -LiteralPath $target)
    }

    $part = Join-Path $Destination (([guid]::NewGuid().ToString('N')) + '.part' + $p.Extension)
    try {
        $null = Invoke-WithRetry -What "Download of $($p.Moniker)" -Action {
            # URLs are short-lived; request a fresh one per attempt.
            $url = Get-Fe3FileUrl -Package $p -DeviceAttributes $DeviceAttributes
            Write-Log ('Downloading {0} ({1:N1} MB)' -f [IO.Path]::GetFileName($target), ($p.Size / 1MB))
            Save-PackageDownload -Url $url -Path $part -TimeoutSeconds $DownloadTimeoutSeconds
            $problem = Test-PackageFile -Path $part -Package $p -SkipSignature
            if ($problem) {
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                throw "verification failed: $problem"
            }
            $problem = Test-PackageFile -Path $part -Package $p
            if ($problem) {
                throw "verification failed: $problem"
            }
            Move-Item -LiteralPath $part -Destination $target -Force
        }
    } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    Write-Log "Downloaded + verified (hash, Microsoft signature): $([IO.Path]::GetFileName($target))"
    return (Get-Item -LiteralPath $target)
}

function Save-OnlinePackages {
    # Resolves, selects and downloads packages for the given families. Returns the downloaded FileInfo objects.
    param(
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string[]] $Families,
        [Parameter(Mandatory)][string] $OsArch,
        [Parameter(Mandatory)][int] $Build
    )
    Initialize-Network
    $attrs = Get-Fe3DeviceAttributes -OsArch $OsArch -Build $Build
    $cookie = Get-Fe3Cookie

    $offered = @{}
    $lookupFailed = @{}
    foreach ($fam in $Families) {
        try {
            $cat = Get-WuCategoryId -PackageFamilyName $fam
            $list = @(Get-Fe3PackageList -CategoryId $cat -Cookie $cookie -DeviceAttributes $attrs)
            Write-Log "Catalog: $fam -> category $cat, $($list.Count) package(s) offered"
            foreach ($p in $list) { $offered[$p.Moniker] = $p }
        }
        catch {
            if ($fam -eq $script:StoreFamily) { throw }
            $lookupFailed[$fam] = $true
            Write-Log "Online lookup failed for ${fam}: $($_.Exception.Message)" 'WARN'
        }
    }

    # Skip encrypted (.eappx*) packages and architectures this machine cannot use.
    $usable = foreach ($p in $offered.Values) {
        if ($p.Extension -like '.e*') { continue }
        $rank = Get-ArchRank -Arch $p.Identity.Arch -OsArch $OsArch -Build $Build
        if ($rank -gt 0) { $p | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -PassThru }
    }

    # Frameworks: newest version per name+arch. Apps: highest Store PackageRank, then newest version, best arch.
    $selected = foreach ($g in ($usable | Group-Object { $_.Identity.Name })) {
        if ($g.Group | Where-Object IsFramework) {
            [void]$script:OnlineFrameworkNames.Add($g.Name)
            foreach ($a in ($g.Group | Group-Object { $_.Identity.Arch })) {
                $a.Group | Sort-Object { $_.Identity.Version } -Descending | Select-Object -First 1
            }
        }
        else {
            $g.Group | Sort-Object @{ Expression = { $_.PackageRank }; Descending = $true },
                @{ Expression = { $_.Identity.Version }; Descending = $true },
                @{ Expression = { $_.Rank }; Descending = $true } |
                Select-Object -First 1
        }
    }
    $selected = @($selected | Sort-Object Moniker)
    if (-not ($selected | Where-Object { $_.Identity.Family -eq $script:StoreFamily })) {
        throw 'The Store service did not offer a usable Microsoft.WindowsStore package'
    }
    $missing = @($Families | Where-Object { $family = $_; $lookupFailed.ContainsKey($family) -or -not ($selected | Where-Object { $_.Identity.Family -eq $family }) })
    foreach ($family in $missing) {
        Add-Failure "Requested app unavailable: $family"
        Write-Log "Requested app unavailable: $family. This run is incomplete." 'WARN'
    }

    # The service offers frameworks for every app version. Download apps first, then only the frameworks
    # their manifests declare (and what those frameworks declare in turn).
    $appPkgs = @($selected | Where-Object { -not $script:OnlineFrameworkNames.Contains($_.Identity.Name) })
    $fwPkgs = @($selected | Where-Object { $script:OnlineFrameworkNames.Contains($_.Identity.Name) })
    Write-Log "Offered: $($appPkgs.Count) app package(s), $($fwPkgs.Count) framework package(s); download folder: $Destination"
    foreach ($p in $selected) { Write-Log ('  {0}{1} ({2:N1} MB)' -f $p.Moniker, $p.Extension, ($p.Size / 1MB)) }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force
    }

    # Remove stale metadata first so an interrupted replacement cannot look complete.
    $manifestPath = Join-Path $Destination 'store-packages.json'
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    $downloaded = New-Object System.Collections.Generic.List[object]
    $pendingManifests = New-Object System.Collections.Generic.Queue[object]
    foreach ($p in $appPkgs) {
        $file = Save-OnlinePackage -Package $p -Destination $Destination -DeviceAttributes $attrs
        $downloaded.Add($file); $pendingManifests.Enqueue($file)
    }
    $neededFw = New-Object System.Collections.Generic.List[object]
    while ($pendingManifests.Count -gt 0) {
        $file = $pendingManifests.Dequeue()
        foreach ($dep in (Get-PackageMetadata -Path $file.FullName -OsArch $OsArch -Build $Build).Dependencies) {
            $expectedFamily = if ($dep.Publisher) { $dep.Name + '_' + (Get-PublisherId $dep.Publisher) } else { $null }
            $matching = @($fwPkgs | Where-Object { $_.Identity.Name -eq $dep.Name -and (-not $expectedFamily -or $_.Identity.Family -eq $expectedFamily) -and ($_.Identity.Arch -eq 'neutral' -or $_.Identity.Arch -eq $dep.Arch) -and $_.Identity.Version -ge $dep.MinVersion })
            foreach ($fw in $matching) {
                if ($neededFw.Contains($fw)) { continue }
                $neededFw.Add($fw)
                $fwFile = Save-OnlinePackage -Package $fw -Destination $Destination -DeviceAttributes $attrs
                $downloaded.Add($fwFile); $pendingManifests.Enqueue($fwFile)
            }
        }
    }
    foreach ($fw in $fwPkgs) {
        if (-not $neededFw.Contains($fw)) { Write-Log "Not downloading $($fw.Moniker)$($fw.Extension): no requested app declares it" }
    }
    $totalMb = [math]::Round(($downloaded | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Write-Log "Downloaded $($downloaded.Count) package(s), $totalMb MB"
    $manifest = [ordered]@{
        SchemaVersion = 1
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        OsArch = $OsArch
        Build = $Build
        RequestedFamilies = @($Families)
        MissingFamilies = @($missing)
        Files = @($downloaded | ForEach-Object { [ordered]@{ Name = $_.Name; Size = $_.Length; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
    }
    $manifestPart = "$manifestPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPart -Encoding UTF8
        Move-Item -LiteralPath $manifestPart -Destination $manifestPath -Force
    } finally { Remove-Item -LiteralPath $manifestPart -Force -ErrorAction SilentlyContinue }
    $downloaded
}
# endregion

try {
    # Pre-flight (language mode first: the checks below need .NET method calls that ConstrainedLanguage blocks)
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Host 'ERROR: PowerShell FullLanguage mode is required.'
        return 3
    }

    # -DownloadOnly installs nothing, so it needs neither admin rights nor a supported build.
    if ($DownloadOnly -and $Source -eq 'Local') {
        Write-Host 'ERROR: -DownloadOnly cannot be combined with -Source Local.'
        return 7
    }

    # Resolve paths before any relaunch, which may start in another directory.
    # WorkDir is empty when run via irm | iex; local packages then come from the current folder only with -Source Local.
    if (-not $WorkDir -and $Source -eq 'Local') { $WorkDir = (Get-Location).ProviderPath }
    $WorkDir = Resolve-UserPath $WorkDir
    $LogDir = Resolve-UserPath $LogDir
    $DownloadDir = Resolve-UserPath $DownloadDir

    if (-not $DownloadOnly -and -not (Test-IsElevated)) {
        if (-not (Test-CanPromptForElevation)) {
            Write-Host 'ERROR: Run this script as Administrator.'
            return 1
        }
        try { return (Invoke-Relaunch -Elevate) }
        catch {
            Write-Host "ERROR: Administrator rights are required ($($_.Exception.Message))."
            return 1
        }
    }

    # Appx/DISM cmdlets need 64-bit Windows PowerShell: relaunch from 32-bit hosts or PowerShell 7.
    if (([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) -or $PSVersionTable.PSEdition -eq 'Core') {
        return (Invoke-Relaunch)
    }

    $osVersionInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$osVersionInfo.CurrentBuildNumber
    $revision = 0
    if ($osVersionInfo.PSObject.Properties['UBR']) { $revision = [int]$osVersionInfo.UBR }
    if (-not $DownloadOnly -and $build -lt 19041) {
        Write-Host 'ERROR: Requires Windows build 19041 or later.'
        return 2
    }

    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
            Write-Host "ERROR: WorkDir not found: $WorkDir"
            return 7
        }
    }

    $script:IsSystem = Test-IsSystemAccount
    $script:DoProvision = -not $NoProvision
    if ($script:IsSystem -and -not $script:DoProvision -and -not $DownloadOnly) {
        Write-Host 'ERROR: -NoProvision cannot be used as SYSTEM (per-user install is not possible for SYSTEM).'
        return 7
    }

    # Log dir: requested/default location, falling back to %TEMP% (e.g. packages on read-only media)
    $tempLogDir = Join-Path ([IO.Path]::GetTempPath()) 'StoreInstall-Logs'
    $logName = 'StoreInstall-{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), ([guid]::NewGuid().ToString('N'))
    $logCandidates = @(
        $(if ($LogDir) { $LogDir } elseif ($WorkDir) { Join-Path $WorkDir 'Logs' } else { $tempLogDir }),
        $tempLogDir
    ) | Select-Object -Unique
    foreach ($dir in $logCandidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $dir -Force
            }
            $candidate = Join-Path $dir $logName
            $null = New-Item -ItemType File -Path $candidate -Force
            $script:LogFile = $candidate
            break
        }
        catch {
            Write-Host "WARN: Cannot write log in ${dir}: $($_.Exception.Message)"
        }
    }

    $osArch = Get-OsArch
    $extensions = @('.appx', '.msix', '.appxbundle', '.msixbundle')
    $localPkgs = @(if ($WorkDir) {
            Get-ChildItem -LiteralPath $WorkDir -File |
                Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
                Sort-Object Name
        })
    $hasLocalStore = $false
    if ($Source -eq 'Auto' -and -not $DownloadOnly) {
        foreach ($localPackage in $localPkgs) {
            try {
                $localIdentity = Get-PackageMetadata -Path $localPackage.FullName -OsArch $osArch -Build $build -Revision $revision
                if ($localIdentity.Supported -and $localIdentity.Name -eq 'Microsoft.WindowsStore' -and (Get-ArchRank -Arch $localIdentity.Arch -OsArch $osArch -Build $build) -gt 0) { $hasLocalStore = $true; break }
            }
            catch { Write-Log "Cannot inspect local candidate '$($localPackage.Name)': $($_.Exception.Message)" 'WARN' }
        }
    }
    $online = $DownloadOnly -or $Source -eq 'Online' -or ($Source -eq 'Auto' -and -not $hasLocalStore)
    $script:IsOnline = $online

    Write-Log '==== Microsoft Store unattended install starting ===='
    Write-Log "Work dir  : $(if ($WorkDir) { $WorkDir } else { '(none)' })"
    Write-Log "Log file  : $(if ($script:LogFile) { $script:LogFile } else { '(console only)' })"
    Write-Log "User      : $env:USERDOMAIN\$env:USERNAME$(if ($script:IsSystem) { ' (SYSTEM: provisioning only)' })"
    Write-Log "Computer  : $env:COMPUTERNAME"
    Write-Log "Build     : $build"
    Write-Log "OS arch   : $osArch (PROCESSOR_ARCHITECTURE=$($env:PROCESSOR_ARCHITECTURE), W6432=$($env:PROCESSOR_ARCHITEW6432))"
    Write-Log "Source    : $(if ($online) { 'Online (Microsoft Store delivery service)' } else { 'Local (work dir)' })$(if ($Source -eq 'Auto') { ' [auto]' })"
    Write-Log "Provision : $($script:DoProvision -and -not $DownloadOnly)"
    Write-Log "SkipWinget: $([bool]$SkipWinget)"

    $script:LicenseDirs = @($WorkDir | Where-Object { $_ })

    $families = @($script:StoreFamily) + $script:OptionalFamilies
    if (-not $SkipWinget) { $families += $script:WingetFamily }

    if ($online) {
        if ($DownloadDir) {
            $pkgDir = $DownloadDir
        }
        else {
            $runToken = [guid]::NewGuid().ToString('N')
            $pkgDir = Join-Path ([IO.Path]::GetTempPath()) ('StoreInstall-Packages-' + $runToken)
            $null = New-Item -ItemType Directory -Path $pkgDir
            Set-Content -LiteralPath (Join-Path $pkgDir '.store-ltsc-owner') -Value $runToken -Encoding ASCII
            if (-not $KeepDownloads -and -not $DownloadOnly) {
                $script:CleanupDir = $pkgDir
                $script:CleanupToken = $runToken
            }
        }

        Write-Log '---- Downloading packages from Microsoft ----'
        try {
            $all = @(Save-OnlinePackages -Destination $pkgDir -Families $families -OsArch $osArch -Build $build)
        }
        catch {
            Write-Log "Download FAILED: $($_.Exception.Message)" 'ERROR'
            Write-Log 'Check internet access to displaycatalog.mp.microsoft.com, fe3.delivery.mp.microsoft.com and *.dl.delivery.mp.microsoft.com (proxy/firewall).' 'ERROR'
            return (Complete-Run 8 'download failed')
        }

        if ($DownloadOnly) {
            Write-Log "Downloaded $($all.Count) package(s) to $pkgDir"
            Write-Log "Install later with: -Source Local -WorkDir `"$pkgDir`""
            if ($script:FailCount -gt 0) { return (Complete-Run 5 'download set incomplete') }
            return (Complete-Run 0 'download only')
        }
    }
    else {
        $all = $localPkgs
        if (-not $WorkDir) {
            Write-Log 'No WorkDir for local packages (use -WorkDir).' 'ERROR'
            return (Complete-Run 4)
        }
        if (Test-Path -LiteralPath (Join-Path $WorkDir 'store-packages.json') -PathType Leaf) {
            $all = @(Test-OfflineManifest -Directory $WorkDir -OsArch $osArch -Build $build -Families $families)
        }
        # Only unblock packages selected for this installation, not unrelated files in WorkDir.
        $unblockErr = @()
        $all | Unblock-File -ErrorAction SilentlyContinue -ErrorVariable unblockErr
        if ($unblockErr.Count -gt 0) {
            foreach ($e in $unblockErr) { Write-Log "Unblock-File warning: $($e.Exception.Message)" 'WARN' }
        }
        else {
            Write-Log 'Unblocked files in work directory (Mark-of-the-Web)'
        }
    }

    if ($all.Count -eq 0) {
        Write-Log 'No Appx/Msix/Bundle packages found.' 'ERROR'
        return (Complete-Run 7)
    }
    Write-Log "Found $($all.Count) package file(s)"

    $frameworks = New-Object System.Collections.Generic.List[object]
    $other = New-Object System.Collections.Generic.List[object]
    $store = $null
    $purchase = $null
    $xboxId = $null
    $winget = $null

    foreach ($f in $all) {
        try { $id = Get-PackageMetadata -Path $f.FullName -OsArch $osArch -Build $build -Revision $revision }
        catch { Write-Log "Cannot read package '$($f.Name)': $($_.Exception.Message)" 'ERROR'; return (Complete-Run 4) }
        if (-not $id.Supported) { Write-Log "Skipping package requiring a newer Windows version: $($f.Name)" 'WARN'; continue }
        $rank = Get-ArchRank -Arch $id.Arch -OsArch $osArch -Build $build
        if ($rank -eq 0) { Write-Log "Skipping package (arch '$($id.Arch)' not usable on $osArch build $build): $($f.Name)"; continue }
        $pkg = [pscustomobject]@{ File = $f; Identity = $id; Rank = $rank }

        if ($id.IsFramework -or (Test-IsFrameworkPackage -Name $id.Name)) {
            $rank = Get-ArchRank -Arch $id.Arch -OsArch $osArch -Build $build
            if ($rank -gt 0) {
                $frameworks.Add($pkg)
            }
            else {
                Write-Log "Skipping framework (arch '$($id.Arch)' not usable on $osArch build $build): $($f.Name)"
            }
            continue
        }

        switch ($id.Name) {
            'Microsoft.WindowsStore'         { $store    = Select-NewerPackage $store $pkg; continue }
            'Microsoft.StorePurchaseApp'     { $purchase = Select-NewerPackage $purchase $pkg; continue }
            'Microsoft.XboxIdentityProvider' { $xboxId   = Select-NewerPackage $xboxId $pkg; continue }
            'Microsoft.DesktopAppInstaller'  { $winget   = Select-NewerPackage $winget $pkg; continue }
            default                          { $other.Add($pkg) }
        }
    }

    if (-not $store) {
        Write-Log 'Required Microsoft Store package not found.' 'ERROR'
        return (Complete-Run 4)
    }

    if (-not $online) {
        foreach ($component in @(
            @{ Name = 'Store Purchase App'; Package = $purchase; Skip = $false },
            @{ Name = 'Xbox Identity Provider'; Package = $xboxId; Skip = $false },
            @{ Name = 'App Installer'; Package = $winget; Skip = [bool]$SkipWinget }
        )) {
            if (-not $component.Package -and -not $component.Skip) {
                Add-Failure "Requested app missing from local packages: $($component.Name)"
                Write-Log "Requested app missing from local packages: $($component.Name). This run is incomplete." 'WARN'
            }
        }
    }

    Write-Log "Store               : $($store.File.Name)"
    Write-Log ('PurchaseApp         : {0}' -f $(if ($purchase) { $purchase.File.Name } else { '(not present)' }))
    Write-Log ('XboxIdentityProvider: {0}' -f $(if ($xboxId) { $xboxId.File.Name } else { '(not present)' }))
    if ($winget -and $SkipWinget) {
        Write-Log 'DesktopAppInstaller : present but skipped (-SkipWinget)'
        $winget = $null
    }
    else {
        Write-Log ('DesktopAppInstaller : {0}' -f $(if ($winget) { $winget.File.Name } else { '(not present)' }))
    }

    # Keep the newest package per identity and architecture before dependency validation.
    $uniqueFw = @{}
    foreach ($fw in $frameworks) {
        $key = '{0}|{1}|{2}' -f $fw.Identity.Name, $fw.Identity.Publisher, $fw.Identity.Arch
        $uniqueFw[$key] = Select-NewerPackage $uniqueFw[$key] $fw
    }
    try {
        # Optional apps with unmet dependencies are skipped (partial failure) so they cannot block the Store.
        $fwCandidates = @($uniqueFw.Values)
        if ($purchase -and -not (Test-OptionalAppDependency $purchase $fwCandidates)) { $purchase = $null }
        if ($xboxId -and -not (Test-OptionalAppDependency $xboxId $fwCandidates)) { $xboxId = $null }
        if ($winget -and -not (Test-OptionalAppDependency $winget $fwCandidates)) { $winget = $null }
        $other = @($other | Where-Object { Test-OptionalAppDependency $_ $fwCandidates })
        $apps = @(@($store, $purchase, $xboxId, $winget) | Where-Object { $null -ne $_ })
        $fwCandidates = @(Select-RequiredFramework -Frameworks $fwCandidates -Applications @($apps + $other))
        $sortedFw = @(Get-DependencyInstallOrder -Frameworks $fwCandidates -Applications @($apps + $other))
    }
    catch { Write-Log $_.Exception.Message 'ERROR'; return (Complete-Run 4) }

    Write-Log '---- Installing framework dependencies ----'
    foreach ($fw in $sortedFw) {
        Write-Log ('Framework (rank {0}): {1}' -f $fw.Rank, $fw.File.Name)
        $null = Install-OnePackage -Package $fw -IsFramework
    }

    # Apps whose install steps succeeded; their result is verified independently below.
    $installedApps = New-Object System.Collections.Generic.List[object]
    Write-Log '---- Installing Microsoft Store ----'
    $storeOk = Install-OnePackage -Package $store
    if ($storeOk) { $installedApps.Add($store) }

    if ($purchase) {
        Write-Log '---- Installing Store Purchase App ----'
        if (Install-OnePackage -Package $purchase) { $installedApps.Add($purchase) }
    }

    if ($xboxId) {
        Write-Log '---- Installing Xbox Identity Provider ----'
        if (Install-OnePackage -Package $xboxId) { $installedApps.Add($xboxId) }
    }

    if ($winget) {
        Write-Log '---- Installing Desktop App Installer (winget) ----'
        if (Install-OnePackage -Package $winget) { $installedApps.Add($winget) }
    }

    foreach ($o in $other) {
        Write-Log "---- Installing additional package: $($o.File.Name) ----"
        if (Install-OnePackage -Package $o) { $installedApps.Add($o) }
    }

    Write-Log '---- Verifying installation ----'
    try {
        if (-not (Test-InstallResult -Applications $installedApps.ToArray())) { $storeOk = $false }
    }
    catch {
        Write-Log "Verification FAILED: $(Format-ErrorText $_.Exception.Message)" 'ERROR'
        Add-Failure 'Installation could not be verified'
    }

    Write-Log '---- Summary ----'
    Write-Log "Store success : $storeOk"
    Write-Log "Failure count : $script:FailCount"
    foreach ($failure in $script:Failures) { Write-Log "  - $failure" }
    Write-Log 'TIP(1): Must run elevated; packages come from the work directory or are downloaded from Microsoft.'
    Write-Log 'TIP(2): Licenses discovered dynamically; SkipLicense used when XML absent.'
    Write-Log 'TIP(3): Only frameworks the apps declare are installed; Store-installed apps bring their own.'
    Write-Log 'TIP(4): See this log + Event Viewer AppXDeployment-Server if Store will not open.'
    Write-Log 'TIP(5): Reboot recommended on clean LTSC/IoT before using Store/winget.'

    if (-not $storeOk) { return (Complete-Run 6 'critical Store failure') }
    if ($script:FailCount -gt 0) { return (Complete-Run 5 'partial failure') }
    return (Complete-Run 0 'success')
}
catch {
    Write-Log "FATAL: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" 'ERROR'
    return (Complete-Run 7)
}
}   # end of Store-LTSC module

# Only the last value is the exit code (guards against stray pipeline output).
$StoreLtscExitCode = @($StoreLtscExitCode) | Select-Object -Last 1
$StoreLtscExitCode = if ($StoreLtscExitCode -is [int]) { $StoreLtscExitCode } else { 7 }
if ($PauseAtEnd) {
    Write-Host ''
    $null = Read-Host "Finished with exit code $StoreLtscExitCode. Press Enter to close"
}
if ($OriginalScriptPath) { exit $StoreLtscExitCode }

# irm | iex: report the result without closing the caller's PowerShell window.
$global:LASTEXITCODE = $StoreLtscExitCode
}

# An outer param block would bind variables in the caller's scope under Invoke-Expression.
# Convert supported named arguments to a splat inside this private child scope instead.
$forward = @{}
$stringParameters = @('WorkDir', 'LogDir', 'Source', 'DownloadDir', 'DownloadTimeoutSeconds', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
$switchParameters = @('DownloadOnly', 'KeepDownloads', 'NoProvision', 'SkipWinget', 'PauseAtEnd', 'Verbose', 'Debug')
for ($index = 0; $index -lt $InvocationArguments.Count; $index++) {
    $argument = [string]$InvocationArguments[$index]
    if ($argument -notmatch '^-(?<Name>[a-zA-Z]+)(?::(?<Value>.*))?$') { throw "Expected a named parameter, received '$argument'." }
    $name = $Matches.Name
    $inlineValue = $Matches.Value
    if ($stringParameters -contains $name) {
        if ($argument.Contains(':') -and $inlineValue -ne '') { $forward[$name] = $inlineValue }
        else {
            if (++$index -ge $InvocationArguments.Count) { throw "Missing value for -$name." }
            $forward[$name] = $InvocationArguments[$index]
        }
    }
    elseif ($switchParameters -contains $name) {
        if (-not $argument.Contains(':')) { $forward[$name] = $true }
        elseif ($inlineValue -eq '' -and ($index + 1) -lt $InvocationArguments.Count -and $InvocationArguments[$index + 1] -is [bool]) {
            $forward[$name] = $InvocationArguments[++$index]
        }
        elseif ($inlineValue -match '^\$?(true|false)$') { $forward[$name] = $Matches[1] -eq 'true' }
        else { throw "Invalid switch value for -$name." }
    }
    else { throw "Unknown parameter -$name." }
}
Invoke-StoreLtsc @forward
} $args $PSCommandPath
