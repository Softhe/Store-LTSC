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
  - Compact console output (one status line per package, live progress in a console window);
    full timestamped log file
  - Works on LTSC 2021 and later: falls back to an older offered app version when the newest
    one needs a newer Windows build
  - Safe to run again: packages already present at the same or a newer version are skipped
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

.PARAMETER TargetBuild
  With -DownloadOnly: pick packages for this Windows build instead of this machine's (e.g. 19044 for LTSC 2021).

.PARAMETER TargetArch
  With -DownloadOnly: pick packages for this architecture (x64, arm64 or x86) instead of this machine's.

.PARAMETER FixServices
  Set Windows services the Store needs (Windows Update, Store Install Service, licensing, Delivery Optimization,
  AppX deployment, ...) from Disabled back to Manual before installing. Without it, disabled services are reported.

.PARAMETER CollectLogs
  Install nothing. Save a diagnostics zip (system details, services, policies, installed packages, AppX event log
  and recent installer logs, with user and computer names removed) to attach to a bug report.

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
    9 Windows is not ready: a service that app installation needs is disabled (see -FixServices), or a restart is
      needed before Windows applies -FixServices

  Tips:
    1. Needs admin rights; packages are downloaded from Microsoft (or taken from -WorkDir).
    2. License XMLs are optional; matched dynamically when present.
    3. Only frameworks the apps declare in their manifests are downloaded and installed.
    4. Failures are written to the log (nothing important is swallowed).
    5. If the Store does not start after installation, restart Windows and try again.
#>

& {
param([object[]] $InvocationArguments, [string] $OriginalScriptPath)

# Keep parameter binding and all implementation variables out of the caller's scope.
$OriginalScriptText = '#Requires -Version 5.1' + [Environment]::NewLine + '& {' + [Environment]::NewLine + $MyInvocation.MyCommand.ScriptBlock.ToString() + [Environment]::NewLine + '} $args $PSCommandPath'
# Release version. The release workflow checks that the pushed tag (v<version>) matches it.
$StoreLtscVersion = '1.0.0'
function Invoke-StoreLtsc {
[CmdletBinding()]
param(
    [string] $WorkDir = $PSScriptRoot,
    [string] $LogDir,
    [ValidateSet('Auto', 'Local', 'Online')][string] $Source = 'Online',
    [string] $DownloadDir,
    [ValidateRange(1, 86400)][int] $DownloadTimeoutSeconds = 1800,
    [ValidateRange(0, 99999)][int] $TargetBuild = 0,
    [string] $TargetArch = '',
    [switch] $DownloadOnly,
    [switch] $KeepDownloads,
    [switch] $NoProvision,
    [switch] $SkipWinget,
    [switch] $FixServices,
    [switch] $CollectLogs,
    [switch] $PauseAtEnd
)

# Everything runs inside a private in-memory module so that, when invoked via irm | iex (which
# executes in the caller's scope), no functions, variables, StrictMode or preference changes leak
# into the user's session, and `exit` never closes their PowerShell window.
$StoreLtscInvocation = @{
    Params     = @{
        WorkDir = $WorkDir; LogDir = $LogDir; Source = $Source; DownloadDir = $DownloadDir
        DownloadTimeoutSeconds = $DownloadTimeoutSeconds
        TargetBuild = $TargetBuild; TargetArch = $TargetArch
        DownloadOnly = [bool]$DownloadOnly; KeepDownloads = [bool]$KeepDownloads
        NoProvision = [bool]$NoProvision; SkipWinget = [bool]$SkipWinget
        FixServices = [bool]$FixServices; CollectLogs = [bool]$CollectLogs
    }
    Bound      = @{}
    ScriptPath = $OriginalScriptPath
    ScriptText = $OriginalScriptText
    Version    = $StoreLtscVersion
}
foreach ($kv in $PSBoundParameters.GetEnumerator()) { $StoreLtscInvocation.Bound[$kv.Key] = $kv.Value }

$StoreLtscExitCode = New-Module -Name 'Store-LTSC' -ArgumentList $StoreLtscInvocation -ReturnResult -ScriptBlock {
param($Invocation)
Export-ModuleMember -Function @()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Appx/DISM progress bars slow down and clutter non-interactive runs

# Defaults for options a caller (or an older relaunch) may not pass.
$TargetBuild = 0; $TargetArch = ''; $FixServices = $false; $CollectLogs = $false
foreach ($kv in $Invocation.Params.GetEnumerator()) { Set-Variable -Name $kv.Key -Value $kv.Value }
$script:BoundParams = $Invocation.Bound
$script:ScriptPath = $Invocation.ScriptPath
$script:ScriptText = $Invocation.ScriptText
$script:Version = if ($Invocation.ContainsKey('Version') -and $Invocation.Version) { [string]$Invocation.Version } else { 'dev' }

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

$script:StatusColors = @{ OK = 'Green'; SKIP = 'DarkCyan'; WARN = 'Yellow'; FAIL = 'Red' }
$script:AppTitles = @{
    'Microsoft.WindowsStore'         = 'Microsoft Store'
    'Microsoft.StorePurchaseApp'     = 'Store Purchase App'
    'Microsoft.XboxIdentityProvider' = 'Xbox Identity Provider'
    'Microsoft.DesktopAppInstaller'  = 'App Installer (winget)'
}

# Console state. In a real console window the step in progress is drawn on one line that is rewritten in place
# (spinner, progress bar, speed, elapsed time). Redirected output (CI, MDT, logs) only gets the permanent lines.
$script:LiveUi = $false
$script:PlainOutput = $false
$script:LiveLength = 0
$script:CursorHidden = $false
$script:Glyph = @{ Full = '#'; Empty = '-'; Rule = '=' }
$script:Spinner = '|', '/', '-', '\'
$script:RunTimer = [Diagnostics.Stopwatch]::StartNew()
$script:Counts = @{ Installed = 0; Present = 0; Failed = 0 }
$script:StepNumber = 0
$script:StepTotal = 0
$script:InstallPosition = ''
$script:Completed = $false
$script:NetworkState = $null
$script:SavedModulePath = $null
# Problems with Windows itself (disabled services, policies, the clock) that do not stop the install but can keep the
# Store from working. They are repeated under the summary whatever the exit code.
$script:Advisories = New-Object System.Collections.Generic.List[string]
$script:WingetLicenseMissing = $false
$script:RestartRequired = $false
# How long verification waits for a registration Windows is still finishing.
$script:RegistrationGraceSeconds = 20

function Initialize-Console {
    $script:LiveUi = $false
    $script:PlainOutput = $false
    try {
        # Output going to a file or pipe gets plain lines: colours do not survive there anyway.
        if ([Console]::IsOutputRedirected) { $script:PlainOutput = $true }
        if ($Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive -and -not [Console]::IsOutputRedirected -and [Console]::WindowWidth -ge 60) {
            # "& .\install.ps1 *> run.log" redirects PowerShell's streams, not the process output, so the checks above
            # still pass while Write-Host goes to the file. Write one space and see whether the cursor moves.
            $left = [Console]::CursorLeft; $top = [Console]::CursorTop
            Write-Host ' ' -NoNewline
            if ([Console]::CursorLeft -eq $left -and [Console]::CursorTop -eq $top) { $script:PlainOutput = $true; return }
            [Console]::SetCursorPosition($left, $top)
            $script:LiveUi = $true
            # East Asian console code pages draw block characters double-width; keep plain ASCII there.
            if (@(932, 936, 949, 950) -notcontains [Console]::OutputEncoding.CodePage) {
                $script:Glyph = @{ Full = [string][char]0x2588; Empty = [string][char]0x2591; Rule = [string][char]0x2500 }
            }
        }
    }
    catch { $script:LiveUi = $false }
}

function Get-ConsoleWidth {
    try { $width = [Console]::WindowWidth; if ($width -ge 40) { return $width } } catch { }
    return 120
}

function Write-ConsoleText {
    # Writes straight to the console window. The transient line must never reach PowerShell's output streams, so a
    # redirected stream or a transcript only ever holds the permanent lines.
    param([AllowEmptyString()][string] $Text, $Color)
    if (-not $Text) { return }
    if (-not $Color) { [Console]::Write($Text); return }
    $previous = [Console]::ForegroundColor
    [Console]::ForegroundColor = $Color
    try { [Console]::Write($Text) } finally { [Console]::ForegroundColor = $previous }
}

function Write-LiveLine {
    # Rewrites the transient line. Each part is @(text, color); the line is cut to the window width so it never wraps.
    param([Parameter(Mandatory)][object[]] $Parts)
    if (-not $script:LiveUi) { return }
    if (-not $script:CursorHidden) { try { [Console]::CursorVisible = $false; $script:CursorHidden = $true } catch { } }
    $max = (Get-ConsoleWidth) - 1
    $used = 0
    Write-ConsoleText "`r"
    foreach ($part in $Parts) {
        $text = [string]$part[0]
        if ($used + $text.Length -gt $max) { $text = $text.Substring(0, [Math]::Max(0, $max - $used)) }
        if (-not $text) { continue }
        Write-ConsoleText $text $part[1]
        $used += $text.Length
    }
    if ($used -lt $script:LiveLength) { Write-ConsoleText (' ' * ($script:LiveLength - $used)) }
    $script:LiveLength = $used
}

function Clear-LiveLine {
    # Erases the transient line so a permanent line can take its place.
    if ($script:LiveLength -gt 0) {
        Write-ConsoleText ("`r" + (' ' * $script:LiveLength) + "`r")
        $script:LiveLength = 0
    }
}

function Restore-Console {
    Clear-LiveLine
    if ($script:CursorHidden) { try { [Console]::CursorVisible = $true } catch { }; $script:CursorHidden = $false }
}

function Format-Clock {
    param([Parameter(Mandatory)][TimeSpan] $Time)
    return '{0}:{1:00}' -f [int][Math]::Floor($Time.TotalMinutes), $Time.Seconds
}

function Format-Duration {
    param([Parameter(Mandatory)][TimeSpan] $Time)
    if ($Time.TotalSeconds -lt 60) { return '{0}s' -f [int][Math]::Round($Time.TotalSeconds) }
    return '{0}m {1:00}s' -f [int][Math]::Floor($Time.TotalMinutes), $Time.Seconds
}

function Show-Activity {
    # The step in progress: spinner, name, an optional progress bar and a detail such as speed or elapsed time.
    # -Detail takes parts in order of importance; a part that does not fit the window is left out, not cut.
    param([Parameter(Mandatory)][string] $Text, [double] $Fraction = -1, [string[]] $Detail)
    if (-not $script:LiveUi) { return }
    $width = (Get-ConsoleWidth) - 1
    $spin = $script:Spinner[[int][Math]::Floor($script:RunTimer.ElapsedMilliseconds / 125) % 4]
    $parts = New-Object System.Collections.Generic.List[object]
    $parts.Add(@(('    {0,-6}' -f $spin), 'Cyan'))
    $parts.Add(@(('{0,-36} ' -f $Text), $null))
    $used = 47
    if ($Fraction -ge 0) {
        $Fraction = [Math]::Min(1.0, $Fraction)
        # The bar takes what the detail leaves over: 10 cells in a 100-column window, up to 24 in a wide one.
        $cells = [Math]::Max(10, [Math]::Min(24, $width - $used - 5 - 40))
        $full = [int][Math]::Floor($Fraction * $cells)
        $parts.Add(@(($script:Glyph.Full * $full), 'Cyan'))
        $parts.Add(@(($script:Glyph.Empty * ($cells - $full)), 'DarkGray'))
        $parts.Add(@((' {0,3}%' -f [int][Math]::Floor($Fraction * 100)), $null))
        $used += $cells + 5
    }
    $shown = ''
    foreach ($piece in @($Detail | Where-Object { $_ })) {
        $next = if ($shown) { "$shown  $piece" } else { $piece }
        if ($used + 2 + $next.Length -gt $width -and $shown) { break }
        $shown = $next
    }
    if ($shown) { $parts.Add(@("  $shown", 'DarkGray')) }
    Write-LiveLine $parts.ToArray()
}

function Split-Line {
    # Word-wraps text for an indented block.
    param([AllowEmptyString()][string] $Text, [int] $Width = 100)
    $Width = [Math]::Max(20, $Width)
    $line = ''
    foreach ($word in ($Text -split '\s+' | Where-Object { $_ })) {
        if ($line -and ($line.Length + 1 + $word.Length) -gt $Width) { $line; $line = $word }
        elseif ($line) { $line += " $word" }
        else { $line = $word }
    }
    if ($line) { $line }
}

function Write-Parts {
    # One permanent line made of @(text, color) parts. When output is redirected, the parts are written as one
    # plain line: in a redirected stream, each Write-Host -NoNewline would otherwise become a line of its own.
    param([Parameter(Mandatory)][object[]] $Parts)
    if ($script:PlainOutput) { Write-Host ((@($Parts) | ForEach-Object { [string]$_[0] }) -join '').TrimEnd(); return }
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        $splat = @{ Object = [string]$Parts[$i][0]; NoNewline = ($i -lt $Parts.Count - 1) }
        if ($Parts[$i][1]) { $splat.ForegroundColor = $Parts[$i][1] }
        Write-Host @splat
    }
}

function Write-StatusLine {
    # Console only: a status column, the text, and an optional dim note. A blank status indents plain text to match.
    param([AllowEmptyString()][string] $Status, [Parameter(Mandatory)][AllowEmptyString()][string] $Text, [string] $Note)
    Clear-LiveLine
    $column = if ($Status) { ,@(('    {0,-6}' -f $Status), $script:StatusColors[$Status]) } else { ,@((' ' * 10), $null) }
    if ($Note) { Write-Parts @($column, @($Text, $null), @("  $Note", 'DarkGray')); return }
    # In a console window, wrap a long message under its own text instead of at the window edge.
    $width = (Get-ConsoleWidth) - 11
    if (-not $script:LiveUi -or $Text.TrimEnd().Length -le $width) { Write-Parts @($column, @($Text.TrimEnd(), $null)); return }
    foreach ($line in (Split-Line $Text $width)) {
        Write-Parts @($column, @($line, $null))
        $column = @((' ' * 10), $null)
    }
}

function Write-Log {
    # Every message goes to the log file with a timestamp. The console shows a shorter view without timestamps:
    # -Quiet keeps a detail out of the console, and -Console replaces the console text.
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO',
        [switch] $Quiet,
        [string] $Console
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $ts, $Level, $Message
    $saved = $false
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8; $saved = $true }
        catch {
            # Report once and continue on the console alone instead of repeating the warning for every line.
            Write-StatusLine 'WARN' "Log file is not writable; details are shown here instead ($($_.Exception.Message))"
            $script:LogFile = $null
        }
    }
    # Without a log file, details would be lost: show the full message instead of hiding or shortening it.
    if ($Quiet -and $saved) { return }
    $text = if ($Console -and $saved) { $Console } else { $Message }
    $status = switch ($Level) { 'WARN' { 'WARN' } 'ERROR' { 'FAIL' } default { '' } }
    Write-StatusLine $status $text
}

function Write-Item {
    # One result line per package or check; the log file keeps the same text with a timestamp.
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'SKIP', 'WARN', 'FAIL')][string] $Status,
        [Parameter(Mandatory)][string] $Text,
        [string] $Note
    )
    $level = switch ($Status) { 'WARN' { 'WARN' } 'FAIL' { 'ERROR' } default { 'INFO' } }
    Write-Log ('{0} {1}{2}' -f $Status, ($Text -replace '\s{2,}', ' ').Trim(), $(if ($Note) { " ($($Note.Trim()))" })) $level -Quiet
    if ($Status -eq 'FAIL' -and $Note) {
        # Error text is long: give it its own indented, wrapped lines instead of running off the row.
        Write-StatusLine $Status $Text
        foreach ($line in (Split-Line $Note ((Get-ConsoleWidth) - 12))) { Write-Host ((' ' * 10) + $line) -ForegroundColor DarkGray }
    }
    else { Write-StatusLine $Status $Text $Note }
}

function Write-Section {
    param([Parameter(Mandatory)][string] $Title)
    Write-Log "---- $Title ----" -Quiet
    Clear-LiveLine
    $script:StepNumber++
    Write-Host ''
    if ($script:StepTotal -gt 1) {
        Write-Parts @(@(('  [{0}/{1}] ' -f $script:StepNumber, $script:StepTotal), 'DarkGray'), @($Title, 'Cyan'))
    }
    else { Write-Host "  $Title" -ForegroundColor Cyan }
}

function Format-AppTitle {
    # "Microsoft.WindowsStore" -> "Microsoft Store"; other names are shown as they are.
    param([Parameter(Mandatory)][string] $Name)
    if ((Test-Path Variable:script:AppTitles) -and $script:AppTitles.ContainsKey($Name)) { return $script:AppTitles[$Name] }
    return $Name
}

function Format-PackageLabel {
    # "Microsoft.UI.Xaml.2.8   8.2501.31001.0   x64  ", padded so result lines and their notes form columns.
    param([Parameter(Mandatory)] $Identity)
    $name = if ($script:AppTitles.ContainsKey([string]$Identity.Name)) { $script:AppTitles[[string]$Identity.Name] } else { [string]$Identity.Name }
    $arch = if ($Identity.Arch -and $Identity.Arch -ne 'neutral') { $Identity.Arch } else { '' }
    return '{0,-36} {1,-16} {2,-5}' -f $name, $Identity.Version, $arch
}

function Format-Brief {
    # Shortens an error for the console; the log file keeps the full text.
    param([AllowNull()][AllowEmptyString()][string] $Text, [int] $Max = 160)
    $Text = (Format-ErrorText $Text) -replace '\s*NOTE: For additional information.*$', ''
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3).TrimEnd() + '...'
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

function Remove-OwnedDownloadDir {
    # Deletes this run's temporary download folder, and only after proving the folder belongs to this run.
    if (-not $script:CleanupDir -or -not (Test-Path -LiteralPath $script:CleanupDir)) { return }
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
}

function Restore-Network {
    # Puts back the session-wide settings this run changed: the module path and Initialize-Network's .NET settings.
    if ($script:SavedModulePath) { $env:PSModulePath = $script:SavedModulePath; $script:SavedModulePath = $null }
    if (-not $script:NetworkState) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = $script:NetworkState.Protocol
        if ($script:NetworkState.Proxy) { $script:NetworkState.Proxy.Credentials = $script:NetworkState.ProxyCredentials }
    }
    catch { }
    $script:NetworkState = $null
}

function Reset-RunState {
    # Runs when the script stops without reaching Complete-Run (Ctrl+C, a closed pipeline, an early exit):
    # leave the console usable, give back the session's network settings and do not strand the downloads.
    try { Restore-Console } catch { }
    try { Restore-Network } catch { }
    try { Remove-OwnedDownloadDir } catch { }
}

function Complete-Run {
    # Cleanup, final log line and console result; returns the exit code (use as: return (Complete-Run 5 'reason')).
    param([Parameter(Mandatory)][int] $Code, [string] $Reason, [string] $Hint)
    Restore-Console
    Restore-Network
    if (-not $Reason) {
        $Reason = switch ($Code) {
            0 { 'Finished' }
            4 { 'A required package or dependency is missing or invalid' }
            5 { 'Finished with problems' }
            6 { 'Microsoft Store could not be installed' }
            8 { 'Download failed' }
            9 { 'Windows is not ready for app installation' }
            default { 'Stopped by an error' }
        }
    }
    if ($script:CleanupDir -and (Test-Path -LiteralPath $script:CleanupDir)) {
        try {
            Remove-OwnedDownloadDir
            Write-Log "Removed downloaded packages: $script:CleanupDir" -Quiet
        }
        catch { Write-Log "Could not remove ${script:CleanupDir}: $($_.Exception.Message)" 'WARN' }
    }
    $elapsed = if ($script:RunTimer) { Format-Duration $script:RunTimer.Elapsed } else { '' }
    Write-Log ('==== finished (exit {0} - {1}) in {2} ====' -f $Code, $Reason, $elapsed) -Quiet

    $color = switch ($Code) { 0 { 'Green' } 5 { 'Yellow' } default { 'Red' } }
    $rule = if ($script:Glyph) { $script:Glyph.Rule } else { '-' }
    Write-Host ''
    Write-Host ('  ' + ($rule * 58)) -ForegroundColor DarkGray
    Write-Host "  $Reason" -ForegroundColor $color
    $facts = New-Object System.Collections.Generic.List[string]
    if ($script:Counts -and ($script:Counts.Installed + $script:Counts.Present + $script:Counts.Failed) -gt 0) {
        $facts.Add("$($script:Counts.Installed) installed")
        if ($script:Counts.Present -gt 0) { $facts.Add("$($script:Counts.Present) already present") }
        if ($script:Counts.Failed -gt 0) { $facts.Add("$($script:Counts.Failed) failed") }
    }
    if ($elapsed) { $facts.Add($elapsed) }
    $facts.Add("exit code $Code")
    Write-Host ('  ' + ($facts -join ', ')) -ForegroundColor DarkGray
    if ($Code -ne 0) { foreach ($failure in @($script:Failures)) { if ($failure) { Write-Host "    - $failure" -ForegroundColor $color } } }
    $advisories = @(if (Test-Path Variable:script:Advisories) { $script:Advisories })
    if ($advisories.Count -gt 0) {
        Write-Host ''
        Write-Host '  Windows settings that can stop Microsoft Store from working:' -ForegroundColor Yellow
        foreach ($advice in $advisories) { Write-Host "    - $advice" -ForegroundColor Yellow }
    }
    if ($Hint) { Write-Host ''; Write-Host "  $Hint" }
    if ($script:LogFile) { Write-Host "  Log: $script:LogFile" -ForegroundColor DarkGray }
    Write-Host ''
    $script:Completed = $true
    return $Code
}

function Test-CanPromptForElevation {
    if (-not [Environment]::UserInteractive -or (Test-IsSystemAccount)) { return $false }
    # Started with -NonInteractive (CI, the .cmd wrapper, scheduled tasks): never pop up UAC.
    return -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' })
}

function Get-WindowsPowerShellModulePath {
    # Windows PowerShell must find its own modules first. A process started from PowerShell 7 inherits that
    # version's module folders (also the Store-packaged one under WindowsApps), where a newer
    # Microsoft.PowerShell.Utility hides Get-FileHash and the Appx module fails to load.
    param([AllowEmptyString()][string] $Current)
    $system = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
    $kept = @($Current -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $system -and $_ -notmatch '\\PowerShell\\|\\Microsoft\.PowerShell_' })
    return (@($system) + $kept) -join ';'
}

function Invoke-Relaunch {
    # Re-runs this script in 64-bit Windows PowerShell, optionally elevated via UAC; returns its exit code.
    param([switch] $Elevate)
    $sysDir = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $psExe = Join-Path $env:SystemRoot "$sysDir\WindowsPowerShell\v1.0\powershell.exe"
    $bound = @{} + $script:BoundParams
    $null = $bound.Remove('PauseAtEnd')

    $tempDir = $null
    $modulePath = $env:PSModulePath
    try {
        # The child inherits this process's module path: hand it one that suits Windows PowerShell.
        if ($PSVersionTable.PSEdition -eq 'Core') { $env:PSModulePath = Get-WindowsPowerShellModulePath $modulePath }
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
        # Without a work folder (irm | iex), the log goes to %TEMP%; a saved copy keeps logging to <WorkDir>\Logs.
        # Not for -CollectLogs: there -LogDir is where the zip goes, and only the user may choose that over the desktop.
        if (-not $bound.ContainsKey('LogDir') -and -not $WorkDir -and -not $CollectLogs) { $bound['LogDir'] = Join-Path ([IO.Path]::GetTempPath()) 'StoreInstall-Logs' }

        foreach ($key in @($bound.Keys)) {
            if ($bound[$key] -is [System.Management.Automation.SwitchParameter]) { $bound[$key] = [bool]$bound[$key] }
        }
        if ($Elevate) { $bound['PauseAtEnd'] = $true }
        # Encode a parameter splat instead of constructing native command-line quoting.
        $parameterData = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize($bound)))
        $bootstrap = '$parameters = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + $parameterData + '''))); & ''' + $file.Replace("'", "''") + ''' @parameters; exit $LASTEXITCODE'
        $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-InputFormat', 'Text', '-OutputFormat', 'Text')
        if (-not $Elevate) { $argList += '-NonInteractive' }
        $argList += '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))

        if ($Elevate) {
            $cmdLine = $argList -join ' '
            Write-Host 'Requesting administrator rights (UAC). The install continues in a new window...' -ForegroundColor Cyan
            $proc = Start-Process -FilePath $psExe -ArgumentList $cmdLine -Verb RunAs -Wait -PassThru
            Write-Host "Elevated run finished with exit code $($proc.ExitCode)." -ForegroundColor DarkGray
            return $proc.ExitCode
        }
        Write-Host '  Continuing in 64-bit Windows PowerShell...' -ForegroundColor DarkGray
        if ($script:LiveUi) {
            # The child shares this console window (not a pipe), so it can draw its progress in place.
            $proc = Start-Process -FilePath $psExe -ArgumentList ($argList -join ' ') -NoNewWindow -Wait -PassThru
            return $proc.ExitCode
        }
        # Output is redirected (a file, a pipe, "*> run.log"): pass the child's lines on as host output, which the
        # caller's redirection captures. A process sharing the console would write past it.
        # Started through .NET, not "& powershell.exe": for a PowerShell parent, the child repeats its output on stderr
        # as CLIXML, which PowerShell decodes into a second copy of every line even with 2>$null. Here stdout is read
        # line by line and stderr is read and dropped.
        $start = New-Object Diagnostics.ProcessStartInfo $psExe
        $start.Arguments = $argList -join ' '   # no argument contains a space or quote
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        try { $start.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
        $child = [Diagnostics.Process]::Start($start)
        try {
            $null = $child.StandardError.ReadToEndAsync()
            while ($null -ne ($line = $child.StandardOutput.ReadLine())) { Write-Host $line }
            $child.WaitForExit()
            return $child.ExitCode
        }
        finally { $child.Dispose() }
    }
    finally {
        $env:PSModulePath = $modulePath
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

function Test-TargetDeviceFamily {
    # True when the TargetDeviceFamily entries (of a package manifest, or of one payload in a bundle manifest)
    # allow this Windows version. No desktop entry means no restriction.
    param([AllowNull()] $Nodes, [Parameter(Mandatory)][version] $OsVersion)
    $targets = @($Nodes | Where-Object { $_ -and (@('Windows.Universal', 'Windows.Desktop') -contains $_.GetAttribute('Name')) })
    if ($targets.Count -eq 0) { return $true }
    return @($targets | Where-Object { -not $_.GetAttribute('MinVersion') -or [version]$_.GetAttribute('MinVersion') -le $OsVersion }).Count -gt 0
}

function Get-PackageMetadata {
    # Read identities from package contents so renamed offline files remain usable.
    param([Parameter(Mandatory)][string] $Path, [string] $OsArch, [int] $Build, [int] $Revision = 0)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $osVersion = [version]("10.0.$Build.$Revision")
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
            # A neutral package runs as the machine's architecture, so that is the framework architecture it needs.
            $depArch = if ($arch -eq 'neutral' -and $OsArch) { $OsArch } else { $arch }
            $deps = @($xml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="PackageDependency"]') | ForEach-Object {
                [pscustomobject]@{ Name = $_.GetAttribute('Name'); Publisher = $_.GetAttribute('Publisher'); MinVersion = $(if ($_.GetAttribute('MinVersion')) { [version]$_.GetAttribute('MinVersion') } else { [version]'0.0.0.0' }); Arch = $depArch }
            })
            $framework = $xml.SelectSingleNode('/*[local-name()="Package"]/*[local-name()="Properties"]/*[local-name()="Framework"]')
            $supported = Test-TargetDeviceFamily -Nodes $xml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="TargetDeviceFamily"]') -OsVersion $osVersion
            $version = [version]$identity.GetAttribute('Version')
            return [pscustomobject]@{ Name = $identity.GetAttribute('Name'); Version = $version; PayloadVersion = $version; Arch = $arch; Family = ($identity.GetAttribute('Name') + '_' + (Get-PublisherId $identity.GetAttribute('Publisher'))); Publisher = $identity.GetAttribute('Publisher'); IsFramework = ($framework -and $framework.InnerText -eq 'true'); Dependencies = $deps; Supported = $supported }
        }
        $manifest = $zip.GetEntry('AppxMetadata/AppxBundleManifest.xml')
        if (-not $manifest) { throw "No Appx package or bundle manifest in '$Path'." }
        $stream = $manifest.Open()
        try { $xml = Read-PackageManifest $stream } finally { $stream.Dispose() }
        $identity = $xml.SelectSingleNode('/*[local-name()="Bundle"]/*[local-name()="Identity"]')
        if (-not $identity) { throw "Bundle identity missing in '$Path'." }
        # Stub payloads (App Installer ships one per architecture) are placeholders, not the app.
        $payloads = @($xml.SelectNodes('/*[local-name()="Bundle"]/*[local-name()="Packages"]/*[local-name()="Package"]') | Where-Object { $_.GetAttribute('Type') -eq 'application' -and $_.GetAttribute('IsStub') -ne 'true' -and (Get-ArchRank -Arch $_.GetAttribute('Architecture') -OsArch $OsArch -Build $Build) -gt 0 })
        # Prefer a payload that supports this Windows version, then the best architecture.
        $best = $payloads | Sort-Object @{ Expression = { [int](Test-TargetDeviceFamily -Nodes $_.SelectNodes('*[local-name()="Dependencies"]/*[local-name()="TargetDeviceFamily"]') -OsVersion $osVersion) }; Descending = $true },
            @{ Expression = { Get-ArchRank -Arch $_.GetAttribute('Architecture') -OsArch $OsArch -Build $Build }; Descending = $true } | Select-Object -First 1
        $deps = @()
        $supported = $true
        $payloadVersion = [version]$identity.GetAttribute('Version')
        if ($best) {
            if ($best.GetAttribute('Version')) { $payloadVersion = [version]$best.GetAttribute('Version') }
            # Bundle manifests may write folder separators as backslashes; zip entries use forward slashes.
            $entry = $zip.GetEntry($best.GetAttribute('FileName').Replace('\', '/'))
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
                # Check the preferred payload. Do not assume Windows will fall back to an emulated payload.
                $supported = Test-TargetDeviceFamily -Nodes $payloadXml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="TargetDeviceFamily"]') -OsVersion $osVersion
                $deps = @($payloadXml.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="PackageDependency"]') | ForEach-Object {
                    [pscustomobject]@{ Name = $_.GetAttribute('Name'); Publisher = $_.GetAttribute('Publisher'); MinVersion = $(if ($_.GetAttribute('MinVersion')) { [version]$_.GetAttribute('MinVersion') } else { [version]'0.0.0.0' }); Arch = $best.GetAttribute('Architecture') }
                })
            }
            finally { $inner.Dispose(); $memory.Dispose() }
        }
        return [pscustomobject]@{ Name = $identity.GetAttribute('Name'); Version = [version]$identity.GetAttribute('Version'); PayloadVersion = $payloadVersion; Arch = $(if ($best) { $best.GetAttribute('Architecture') } else { 'unsupported' }); Family = ($identity.GetAttribute('Name') + '_' + (Get-PublisherId $identity.GetAttribute('Publisher'))); Publisher = $identity.GetAttribute('Publisher'); IsFramework = $false; Dependencies = $deps; Supported = $supported }
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
            # The provisioned list is read once per run (a DISM query takes seconds).
            $installed = @(Get-ProvisionedIdentity | Where-Object {
                $_.Name -eq $dep.Name -and $_.Version -ge $dep.MinVersion -and (-not $expectedFamily -or $_.Family -eq $expectedFamily) -and ($_.Arch -eq 'neutral' -or $_.Arch -eq $dep.Arch)
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

function Test-SameOrNewerVersion {
    # Xbox Identity Provider version numbers are not monotonic: the legacy 2017.x line is older than 12.x.
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][version] $Installed, [Parameter(Mandatory)][version] $Offered)
    if ($Name -eq 'Microsoft.XboxIdentityProvider' -and ($Installed.Major -ge 2000) -ne ($Offered.Major -ge 2000)) {
        return $Offered.Major -ge 2000
    }
    return $Installed -ge $Offered
}

function Find-InstalledFramework {
    # Packages with the same identity (name, publisher, architecture) at version >= the given package.
    # -App compares an app instead: any architecture, and the bundle's payload version for registered copies
    # (a registered app reports its payload version, a provisioned one the bundle version).
    param(
        [Parameter(Mandatory)] $Identity,
        [Parameter(Mandatory)][ValidateSet('Provisioned', 'CurrentUser', 'AllUsers')][string] $Scope,
        [switch] $App
    )
    if ($Scope -eq 'Provisioned') {
        return @(Get-ProvisionedIdentity | Where-Object { $_.Name -eq $Identity.Name -and $_.Family -eq $Identity.Family -and ($App -or $_.Arch -eq $Identity.Arch) -and $_.Version -and (Test-SameOrNewerVersion $Identity.Name $_.Version $Identity.Version) } |
            Sort-Object Version -Descending)
    }
    $offered = if ($App -and $Identity.PSObject.Properties['PayloadVersion'] -and $Identity.PayloadVersion) { $Identity.PayloadVersion } else { $Identity.Version }
    $packages = if ($Scope -eq 'AllUsers') { Get-AppxPackage -AllUsers -Name $Identity.Name -ErrorAction SilentlyContinue } else { Get-AppxPackage -Name $Identity.Name -ErrorAction SilentlyContinue }
    # A current-user copy that needs repair must not suppress re-registration.
    return @($packages | Where-Object { $_.Publisher -eq $Identity.Publisher -and ($App -or $_.Architecture.ToString() -eq $Identity.Arch) -and (Test-SameOrNewerVersion $Identity.Name ([version]$_.Version) $offered) -and ($Scope -ne 'CurrentUser' -or [string]$_.Status -eq 'Ok') } |
        Sort-Object { [version]$_.Version } -Descending)
}

function Test-InstallResult {
    # Confirms the result with Windows instead of trusting cmdlet success: current-user registration and, when
    # provisioning, that every app and each dependency of the apps and installed frameworks is provisioned for new users.
    # Returns $false if the Store is not registered.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Applications, [object[]] $Frameworks = @())
    $storeRegistered = $true
    $wingetRegistered = $false
    if (-not $script:IsSystem -and @($Applications).Count -gt 0) {
        $verified = 0
        foreach ($app in $Applications) {
            $registered = @(Get-AppxPackage -Name $app.Identity.Name -ErrorAction SilentlyContinue | Where-Object { [string]$_.Status -eq 'Ok' })
            # Windows can still be servicing a package it registered moments ago, for example adding a language
            # resource pack, and leaves it out of the list meanwhile. Seen on 2026-11-24: App Installer was registered
            # with status Ok, missing in the same second while its Swedish resource pack was added, then Ok again.
            for ($wait = 1; $registered.Count -eq 0 -and $wait -le $script:RegistrationGraceSeconds; $wait++) {
                Start-Sleep -Seconds 1
                $registered = @(Get-AppxPackage -Name $app.Identity.Name -ErrorAction SilentlyContinue | Where-Object { [string]$_.Status -eq 'Ok' })
                if ($registered.Count -gt 0) { Write-Log "$($app.Identity.Name) was registered after $wait more second(s)" -Quiet }
            }
            if ($registered.Count -gt 0) {
                Write-Log "Verified (current user): $($app.Identity.Name) $($registered[0].Version), status Ok" -Quiet
                $verified++
                if ($app.Identity.Name -eq 'Microsoft.DesktopAppInstaller') { $wingetRegistered = $true }
                continue
            }
            Write-Log "Not registered for the current user after installation: $($app.Identity.Name)" 'ERROR'
            Add-Failure "$($app.Identity.Name) is not registered for the current user"
            if ($app.Identity.Name -eq 'Microsoft.WindowsStore') { $storeRegistered = $false }
        }
        if ($verified -gt 0) { Write-Item $(if ($verified -eq @($Applications).Count) { 'OK' } else { 'WARN' }) "This user: $verified of $(@($Applications).Count) app(s) registered and ready" }
        if ($wingetRegistered) { $null = Test-WingetCommand }
    }
    if (-not $script:DoProvision) { return $storeRegistered }

    $provisioned = @(Get-ProvisionedIdentity -Refresh)
    $problems = 0
    $appNames = @($Applications | ForEach-Object { $_.Identity.Name })
    # Frameworks' own dependencies count too: an app can rely on them through a framework.
    foreach ($pkg in @($Applications) + @($Frameworks)) {
        $isApp = $appNames -contains $pkg.Identity.Name
        if ($isApp -and -not ($provisioned | Where-Object { $_.Name -eq $pkg.Identity.Name -and $_.Family -eq $pkg.Identity.Family })) {
            $problems++
            Write-Log "Not provisioned for new users after installation: $($pkg.Identity.Name)" 'ERROR'
            Add-Failure "$($pkg.Identity.Name) is not provisioned for new users"
            continue
        }
        foreach ($dep in $pkg.Identity.Dependencies) {
            $expectedFamily = if ($dep.Publisher) { $dep.Name + '_' + (Get-PublisherId $dep.Publisher) } else { $null }
            $match = @($provisioned | Where-Object { $_.Name -eq $dep.Name -and (-not $expectedFamily -or $_.Family -eq $expectedFamily) -and ($_.Arch -eq 'neutral' -or $_.Arch -eq $dep.Arch) -and $_.Version -ge $dep.MinVersion })
            if ($match.Count -gt 0) { continue }
            $problems++
            Write-Log "New users: $($pkg.Identity.Name) needs $($dep.Name) $($dep.MinVersion) or newer ($($dep.Arch)), which is not provisioned." 'ERROR'
            Add-Failure "$($dep.Name) ($($dep.Arch)) for $($pkg.Identity.Name) is not provisioned for new users"
        }
    }
    if ($problems -eq 0) {
        Write-Item OK "New users: $(@($Applications).Count) app(s) provisioned with all dependencies"
        foreach ($name in $script:SupersededFrameworks) {
            Write-Log "Not provisioning ${name} is harmless: newer provisioned frameworks satisfy every app dependency." -Quiet
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
    $unused = @($Frameworks | Where-Object { -not $required.Contains($_) })
    foreach ($fw in $unused) { Write-Log "Skipping framework no app declares: $($fw.File.Name)" -Quiet }
    if ($unused.Count -gt 0) { Write-Log "Skipping $($unused.Count) framework package(s) that no app needs" -Quiet:$script:IsOnline }
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
        $xmlFiles = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.xml' -ErrorAction SilentlyContinue | Sort-Object Name)
        $cand = $xmlFiles | Where-Object { $_.Name -like ($Identity.Name + '_*') -or $_.Name -eq ($Identity.Name + '.xml') } | Select-Object -First 1
        if ($cand) { return $cand.FullName }

        # Otherwise read the licenses themselves: the winget release names its file "<hash>_License1.xml".
        if ($Identity.Family) {
            $cand = $xmlFiles | Where-Object { $_.Length -le 65536 -and (Test-StoreLicense -Path $_.FullName -Family $Identity.Family) } | Select-Object -First 1
            if ($cand) { return $cand.FullName }
        }
    }
    return $null
}

function Test-StoreLicense {
    # True when the file is a signed Store license for the given package family name.
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Family)
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { $xml = Read-PackageManifest $stream } finally { $stream.Dispose() }
        $root = $xml.DocumentElement
        if (-not $root -or $root.LocalName -ne 'License' -or $root.NamespaceURI -ne 'urn:schemas-microsoft-com:windows:store:licensing:ls') { return $false }
        $pfm = $root.SelectSingleNode('*[local-name()="Binding"]/*[local-name()="PFM"]')
        $signature = $root.SelectSingleNode('*[local-name()="Signature"]')
        return [bool]($pfm -and $signature -and [string]::Equals($pfm.InnerText.Trim(), $Family, [StringComparison]::OrdinalIgnoreCase))
    }
    catch { return $false }
}

function Copy-LicenseToFolder {
    # Copies a license into a package folder as "<PackageFamilyName>.xml", unless it is already there.
    # Returns the license path inside the folder.
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Destination, [Parameter(Mandatory)][string] $Family)
    $target = Join-Path $Destination ($Family + '.xml')
    $source = [IO.Path]::GetFullPath($Path)
    if ([string]::Equals($source, [IO.Path]::GetFullPath($target), [StringComparison]::OrdinalIgnoreCase)) { return $target }
    if ([string]::Equals([IO.Path]::GetDirectoryName($source).TrimEnd('\'), [IO.Path]::GetFullPath($Destination).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $source }
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-Log "Copied the license $([IO.Path]::GetFileName($source)) into the package folder as $([IO.Path]::GetFileName($target))" -Quiet
    return $target
}

function Save-WingetLicense {
    # App Installer only runs winget when it was provisioned with its license: without one, winget fails with
    # "No applicable app licenses found". The Store delivery service offers no license, but each winget release
    # on GitHub publishes it. Saves it into the package folder under the package family name; Windows checks
    # the license signature when the package is provisioned. Returns the path, or $null when it is unavailable.
    param([Parameter(Mandatory)][string] $Destination)
    $target = Join-Path $Destination ($script:WingetFamily + '.xml')
    if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Test-StoreLicense -Path $target -Family $script:WingetFamily)) { return $target }
    $part = "$target.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Show-Activity -Text 'App Installer license' -Detail 'github.com/microsoft/winget-cli'
        $asset = Get-WingetLicenseAsset
        if ([string]$asset.Url -notmatch '^https://github\.com/microsoft/winget-cli/releases/download/[^/?#]+/[^/?#]+_License1\.xml$') {
            throw "unexpected license address $($asset.Url)"
        }
        $null = Invoke-WithRetry -What 'winget license download' -Attempts 2 -Action {
            Invoke-WebRequest -Uri $asset.Url -OutFile $part -UseBasicParsing -TimeoutSec 60
        }
        if ((Get-Item -LiteralPath $part).Length -gt 65536 -or -not (Test-StoreLicense -Path $part -Family $script:WingetFamily)) { throw 'the downloaded file is not a signed license for App Installer' }
        Move-Item -LiteralPath $part -Destination $target -Force
        Write-Log "App Installer license: $($asset.Name) from winget $($asset.Tag)" -Quiet
        Write-Item OK (Format-PackageLabel ([pscustomobject]@{ Name = 'App Installer license'; Version = $asset.Tag; Arch = '' })) 'from github.com/microsoft/winget-cli'
        return $target
    }
    catch {
        $script:WingetLicenseMissing = $true
        Write-Log "App Installer license unavailable: $($_.Exception.Message)" 'WARN' -Console "App Installer license could not be downloaded ($($_.Exception.Message)); winget will report 'No applicable app licenses found'"
        Add-Failure 'App Installer license unavailable: winget will not run'
        return $null
    }
    finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
}

function Get-WingetLicenseAsset {
    # The license file of the latest winget release, as @{ Tag; Name; Url }. Asks the GitHub API first. The API allows
    # 60 unauthenticated requests per hour per address, which offices and schools behind one address can use up, so
    # the release page is the fallback.
    try {
        $release = Invoke-WithRetry -What 'winget release lookup' -Attempts 2 -Action {
            Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing -TimeoutSec 30
        }
        $asset = @($release.assets | Where-Object { $_.name -match '_License1\.xml$' -and $_.size -le 65536 }) | Select-Object -First 1
        if (-not $asset) { throw "release $($release.tag_name) has no license file" }
        return [pscustomobject]@{ Tag = [string]$release.tag_name; Name = [string]$asset.name; Url = [string]$asset.browser_download_url }
    }
    catch {
        Write-Log "GitHub API lookup failed ($($_.Exception.Message)); reading the release page instead" 'WARN' -Quiet
    }
    # /releases/latest redirects to /releases/tag/<tag>; the asset list of a release is served as a page fragment.
    $latest = Invoke-WithRetry -What 'winget release page' -Attempts 2 -Action {
        Invoke-WebRequest -Uri 'https://github.com/microsoft/winget-cli/releases/latest' -UseBasicParsing -TimeoutSec 30
    }
    $finalUri = [string]$latest.BaseResponse.ResponseUri
    if ($finalUri -notmatch '/releases/tag/(?<tag>[A-Za-z0-9._-]+)$') { throw "could not find the latest winget release ($finalUri)" }
    $tag = $Matches['tag']
    $assets = Invoke-WithRetry -What 'winget release assets' -Attempts 2 -Action {
        Invoke-WebRequest -Uri "https://github.com/microsoft/winget-cli/releases/expanded_assets/$tag" -UseBasicParsing -TimeoutSec 30
    }
    if ([string]$assets.Content -notmatch 'href="(?<path>/microsoft/winget-cli/releases/download/[^"/]+/(?<name>[^"/]+_License1\.xml))"') { throw "release $tag has no license file" }
    return [pscustomobject]@{ Tag = $tag; Name = $Matches['name']; Url = 'https://github.com' + $Matches['path'] }
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

function Invoke-Deployment {
    # Runs one Appx/DISM cmdlet. In a console window it runs on a second runspace so this one stays free to draw
    # a spinner, the elapsed time and the cmdlet's own progress. Otherwise it is called directly.
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][hashtable] $Parameters,
        [string] $Activity = $Command,
        [string] $Detail
    )
    if (-not $script:LiveUi) { $null = & $Command @Parameters; return }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $async = $null
    $shell = [powershell]::Create()
    try {
        $null = $shell.AddCommand($Command).AddParameters($Parameters)
        $async = $shell.BeginInvoke()
        while (-not $async.IsCompleted) {
            $fraction = -1
            $count = $shell.Streams.Progress.Count
            if ($count -gt 0) {
                $record = $shell.Streams.Progress[$count - 1]
                if ($record.PercentComplete -gt 0 -and $record.PercentComplete -le 100) { $fraction = $record.PercentComplete / 100 }
            }
            Show-Activity -Text $Activity -Fraction $fraction -Detail (('{0}  {1}' -f $Detail, (Format-Clock $timer.Elapsed)).Trim())
            Start-Sleep -Milliseconds 120
        }
        try { $null = $shell.EndInvoke($async) }
        catch {
            $failure = $_.Exception
            while ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
            throw $failure
        }
        # The cmdlets report failures as non-terminating errors, which the direct call turns into exceptions.
        if ($shell.Streams.Error.Count -gt 0) { throw $shell.Streams.Error[0].Exception }
    }
    finally {
        if ($async -and -not $async.IsCompleted) { try { $shell.Stop() } catch { } }
        $shell.Dispose()
    }
}

function Install-OnePackage {
    # Provisions (for new users) and registers (for the current user) one package. Details go to the log file;
    # the console gets a single result line.
    param(
        [Parameter(Mandatory)] $Package,
        [switch] $IsFramework
    )

    $path = $Package.File.FullName
    $name = $Package.File.Name
    $isApp = -not $IsFramework
    $title = if ($script:AppTitles.ContainsKey([string]$Package.Identity.Name)) { $script:AppTitles[[string]$Package.Identity.Name] } else { [string]$Package.Identity.Name }
    $position = if ($script:InstallPosition) { "$script:InstallPosition, " } else { '' }
    $ok = $true
    $changed = $false     # something was provisioned or registered
    $present = $null      # version of a same or newer copy that made a step unnecessary
    $problem = $null
    $notes = New-Object System.Collections.Generic.List[string]
    $warn = $false        # installed, but with a problem the result line must show
    $needsLicense = $Package.Identity.Name -eq 'Microsoft.DesktopAppInstaller'

    $license = $null
    if ($isApp -and $script:DoProvision) {
        $license = Find-License -PackagePath $path -Identity $Package.Identity
        if ($license) { Write-Log "License for ${name}: $([IO.Path]::GetFileName($license))" -Quiet }
    }

    # Windows cannot deploy an older copy over a newer one, and a Store that updated itself must not be rolled back
    # by an older download or offline folder: skip the step instead of failing.
    $provisioned = @(if ($script:DoProvision) { Find-InstalledFramework -Identity $Package.Identity -Scope Provisioned -App:$isApp })
    # The same version may have been provisioned without its license (by an earlier run): provisioning it again
    # with the license adds it. Nothing else changes, so this is safe to repeat.
    $addLicense = $license -and $provisioned.Count -gt 0 -and $provisioned[0].Version -eq $Package.Identity.Version
    if ($provisioned.Count -gt 0 -and -not $addLicense) {
        Write-Log "Already provisioned: $name (version $($provisioned[0].Version) present)" -Quiet
        $present = $provisioned[0].Version
    }
    elseif ($script:DoProvision) {
        if ($isApp -and -not $license) {
            # Most Store apps run without one. App Installer does not: winget then reports "No applicable app licenses found".
            Write-Log "No license XML for ${name}; provisioning with -SkipLicense" $(if ($script:IsOnline -and -not $needsLicense) { 'INFO' } else { 'WARN' }) -Quiet
            if ($needsLicense) {
                $warn = $true
                $script:WingetLicenseMissing = $true
                $notes.Add('no license file: winget will not run')
                # Online runs already counted the failed license download.
                if (-not $script:IsOnline) { Add-Failure 'App Installer has no license file: winget will not run (add the *_License1.xml from the winget release)' }
            }
            elseif (-not $script:IsOnline) { $notes.Add('no license file, used -SkipLicense') }
        }
        if ($addLicense) { Write-Log "Provisioning $name again to add its license" -Quiet; $notes.Add('license added') }

        try {
            Write-Log "Provisioning: $name" -Quiet
            $provision = @{ Online = $true; PackagePath = $path }
            if ($license) { $provision.LicensePath = $license; $provision.Regions = 'all' } else { $provision.SkipLicense = $true }
            Invoke-Deployment -Command 'Add-AppxProvisionedPackage' -Parameters $provision -Activity $title -Detail "${position}adding for new users"
            $script:ProvisionedCache = $null
            Write-Log "Provisioned OK: $name" -Quiet
            $changed = $true
        }
        catch {
            $msg = Format-ErrorText $_.Exception.Message
            $code = Get-DeploymentErrorCode $_
            if ($code) { $msg = "[$code] $msg" }
            # DISM can reject an older package when a newer one is already installed ("Element not found").
            # The post-install check decides whether new users still get everything. That does not apply when the
            # step was only adding a license: the installed copy is the one still missing it, so this is a failure.
            $newer = @(if (-not $addLicense) { Find-InstalledFramework -Identity $Package.Identity -Scope AllUsers -App:$isApp })
            if ($newer.Count -gt 0) {
                Write-Log "Provision not applied: $name :: $msg" 'WARN' -Quiet
                Write-Log "Version $($newer[0].Version) of this package is already installed on this machine; new-user availability is verified after installation." 'WARN' -Quiet
                if ($IsFramework) { $script:SupersededFrameworks.Add($name) }
                $present = $newer[0].Version
            }
            else {
                Write-Log "Provision FAILED: $name :: $msg" 'ERROR' -Quiet
                $ok = $false
                $problem = "provisioning failed: $msg"
                Add-Failure "Provisioning failed: $name"
            }
        }
    }

    if ($script:IsSystem) {
        # Add-AppxPackage cannot register packages for the SYSTEM account; provisioning covers all users.
        Write-Log "Per-user install skipped (running as SYSTEM): $name" -Quiet
    }
    else {
        $registered = @(Find-InstalledFramework -Identity $Package.Identity -Scope CurrentUser -App:$isApp)
        if ($registered.Count -gt 0) {
            Write-Log "Already registered (current user): $name (version $($registered[0].Version) present)" -Quiet
            if (-not $present) { $present = $registered[0].Version }
        }
        else {
            try {
                Write-Log "Installing (current user): $name" -Quiet
                $register = @{ Path = $path; ForceApplicationShutdown = $true }
                # Only the legacy Xbox Identity Provider (2017.x) has a higher version number than its replacement.
                if ($Package.Identity.Name -eq 'Microsoft.XboxIdentityProvider') { $register.ForceUpdateFromAnyVersion = $true }
                Invoke-Deployment -Command 'Add-AppxPackage' -Parameters $register -Activity $title -Detail "${position}registering for this user"
                Write-Log "Install OK: $name" -Quiet
                $changed = $true
            }
            catch {
                $msg = Format-ErrorText $_.Exception.Message
                $code = Get-DeploymentErrorCode $_
                if ($code) { $msg = "[$code] $msg" }
                # Non-fatal: 0x80073D06 = higher version already installed, 0x80073CFB = same identity already installed.
                # The code is read from the exception; the English text is only a fallback for older error formats.
                if (@('0x80073D06', '0x80073CFB') -contains $code -or $msg -match '0x80073D06|0x80073CFB|higher version|already installed') {
                    Write-Log "Install skipped/non-fatal: $name :: $msg" 'WARN' -Quiet
                    if (-not $present) {
                        # Ask Windows for the installed version instead of parsing it from the (localized) error text.
                        $installed = @(Find-InstalledFramework -Identity $Package.Identity -Scope AllUsers -App:$isApp)
                        if ($installed.Count -gt 0) { $present = $installed[0].Version }
                        elseif ($msg -match 'higher version (\d+(?:\.\d+){1,3})') { $present = $Matches[1] }
                    }
                    # A newer copy exists on the machine but this user has none: register that copy instead.
                    $healthy = @(Get-AppxPackage -Name $Package.Identity.Name -ErrorAction SilentlyContinue | Where-Object { [string]$_.Status -eq 'Ok' })
                    if ($isApp -and $Package.Identity.Family -and $healthy.Count -eq 0) {
                        try {
                            Invoke-Deployment -Command 'Add-AppxPackage' -Parameters @{ RegisterByFamilyName = $true; MainPackage = $Package.Identity.Family } -Activity $title -Detail "${position}registering the installed copy"
                            Write-Log "Registered the newer installed copy for the current user: $($Package.Identity.Family)" -Quiet
                            $changed = $true
                        }
                        catch { Write-Log "Could not register the installed copy of $($Package.Identity.Family): $(Format-ErrorText $_.Exception.Message)" 'WARN' -Quiet }
                    }
                }
                else {
                    Write-Log "Install FAILED: $name :: $msg" 'ERROR' -Quiet
                    $ok = $false
                    if (-not $problem) { $problem = "install failed: $msg" }
                    Add-Failure "Install failed (current user): $name"
                }
            }
        }
    }

    $label = Format-PackageLabel $Package.Identity
    if (-not $ok) { $script:Counts.Failed++; Write-Item FAIL $label (Format-Brief $problem 600) }
    elseif ($changed) { $script:Counts.Installed++; Write-Item $(if ($warn) { 'WARN' } else { 'OK' }) $label ($notes -join '; ') }
    else {
        $script:Counts.Present++
        $skipNote = if ($present) { "version $present already installed" } else { 'already installed' }
        if ($warn) { Write-Item WARN $label ((@($skipNote) + @($notes)) -join '; ') } else { Write-Item SKIP $label $skipNote }
    }
    return $ok
}
# endregion

# region Windows readiness
# Services Microsoft Store and app installation depend on. LTSC "debloat" scripts often disable them; the install
# then reports success, but the Store cannot download, license or install apps (typically error 0x80070422).
# Required: app installation itself fails without it. Default: the start type -FixServices restores.
$script:StoreServices = @(
    [pscustomobject]@{ Name = 'AppXSvc';         Title = 'AppX Deployment Service';         Use = 'installing apps';                 Required = $true }
    [pscustomobject]@{ Name = 'StateRepository'; Title = 'State Repository Service';        Use = 'installing and starting apps';    Required = $true }
    [pscustomobject]@{ Name = 'ClipSVC';         Title = 'Client License Service';          Use = 'Store app licenses';              Required = $false }
    [pscustomobject]@{ Name = 'LicenseManager';  Title = 'Windows License Manager';         Use = 'Store app licenses';              Required = $false }
    [pscustomobject]@{ Name = 'InstallService';  Title = 'Microsoft Store Install Service'; Use = 'Store downloads';                 Required = $false }
    [pscustomobject]@{ Name = 'wuauserv';        Title = 'Windows Update';                  Use = 'Store downloads and app updates'; Required = $false }
    [pscustomobject]@{ Name = 'DoSvc';           Title = 'Delivery Optimization';           Use = 'Store downloads';                 Required = $false }
    [pscustomobject]@{ Name = 'TokenBroker';     Title = 'Web Account Manager';             Use = 'signing in to the Store';         Required = $false }
)
# Policies that keep an installed Store from working. They are an administrator's decision, so they are reported,
# never changed. UserToo: the policy also exists under HKCU (User Configuration).
$script:StorePolicies = @(
    [pscustomobject]@{ Key = 'SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'RemoveWindowsStore'; Text = 'turns off the Microsoft Store app'; UserToo = $true }
    [pscustomobject]@{ Key = 'SOFTWARE\Policies\Microsoft\WindowsStore'; Name = 'DisableStoreApps'; Text = 'turns off all Store apps'; UserToo = $false }
    [pscustomobject]@{ Key = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Text = 'blocks the Windows Update servers that Store downloads use'; UserToo = $false }
)

function Get-ServiceStartValue {
    # The service's Start value (2 automatic, 3 manual, 4 disabled), or $null when the service does not exist.
    # Read from the registry: protected services such as ClipSVC are not always visible to Get-Service.
    param([Parameter(Mandatory)][string] $Name)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$Name")
    if (-not $key) { return $null }
    try {
        $value = $key.GetValue('Start')
        if ($null -eq $value) { return $null }
        return [int]$value
    }
    finally { $key.Dispose() }
}

function Set-ServiceManual {
    # Sets a disabled service to Manual: Windows starts it when an app or the Store asks for it. Returns $true when the
    # change applies now, $false when it applies only after Windows restarts.
    # AppXSvc, ClipSVC and DoSvc refuse configuration through the service manager even to administrators (only
    # TrustedInstaller may change AppXSvc). Their registry value can still be written, but the service manager reads it
    # only at startup: until Windows restarts it keeps treating the service as disabled, although every query (sc qc,
    # Get-Service) already reports Manual. Seen on Windows 11 IoT Enterprise LTSC 2024, 2026-11-23.
    param([Parameter(Mandatory)][string] $Name)
    $now = $true
    try { Set-Service -Name $Name -StartupType Manual -ErrorAction Stop }
    catch {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\$Name", $true)
        if (-not $key) { throw }
        try { $key.SetValue('Start', 3, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
        Write-Log "Service manager refused to change $($Name) ($(Format-ErrorText $_.Exception.Message)); set its registry value, which applies after a restart" -Quiet
        $now = $false
    }
    if ((Get-ServiceStartValue $Name) -ne 3) { throw "the start type of $Name did not change" }
    return $now
}

function Test-ServiceCanStart {
    # Starts a stopped service to prove Windows will run it. Returns $false only when Windows refuses because it still
    # treats the service as disabled (error 1058): a start type changed in the registry applies after a restart.
    param([Parameter(Mandatory)][string] $Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -ne 'Stopped') { return $true }
    try { Start-Service -Name $Name -ErrorAction Stop; Write-Log "Started service $Name to check that it runs" -Quiet; return $true }
    catch {
        for ($e = $_.Exception; $e; $e = $e.InnerException) {
            if ($e -is [ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1058) { return $false }
        }
        # Any other start problem is left to the deployment step, which reports its own error.
        Write-Log "Could not start $($Name): $(Format-ErrorText $_.Exception.Message)" 'WARN' -Quiet
        return $true
    }
}

function Get-PolicyValue {
    param([Parameter(Mandatory)][ValidateSet('LocalMachine', 'CurrentUser')][string] $Hive, [Parameter(Mandatory)][string] $Key, [Parameter(Mandatory)][string] $Name)
    $root = if ($Hive -eq 'LocalMachine') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
    $subKey = $root.OpenSubKey($Key)
    if (-not $subKey) { return $null }
    try { return $subKey.GetValue($Name) } finally { $subKey.Dispose() }
}

function Invoke-SystemReadiness {
    # Checks the services and policies Microsoft Store depends on, and with -FixServices re-enables disabled services.
    # Problems that do not stop the install become advisories. Returns $false when app installation cannot work.
    param([AllowEmptyString()][string] $InstallationType)
    $ready = $true
    $problems = 0
    $script:RestartRequired = $false
    $restartAdvised = $false
    foreach ($svc in $script:StoreServices) {
        $start = Get-ServiceStartValue $svc.Name
        if ($null -ne $start -and $start -ne 4) {
            Write-Log "Service $($svc.Name): start type $start" -Quiet
            # The registry can say Manual while Windows still treats the service as disabled (changed without a restart).
            if ($svc.Required -and -not (Test-ServiceCanStart $svc.Name)) {
                $problems++; $ready = $false; $script:RestartRequired = $true
                Write-Log "Service $($svc.Name) is set to start type $start, but Windows refuses to start it until it restarts" 'WARN' -Quiet
                Write-Item FAIL $svc.Title 'Windows treats it as disabled until it restarts'
            }
            continue
        }
        $problems++
        $state = if ($null -eq $start) { 'missing from Windows' } else { 'disabled' }
        if ($null -ne $start -and $FixServices) {
            try {
                $appliesNow = Set-ServiceManual $svc.Name
                Write-Log "Service $($svc.Name) was disabled; set to Manual (-FixServices)$(if (-not $appliesNow) { ', after a restart' })" -Quiet
                if ($appliesNow) { Write-Item OK $svc.Title 'was disabled, now Manual (starts when needed)'; continue }
                if ($svc.Required) {
                    # Installing now would fail with "The service cannot be started ... because it is disabled".
                    $ready = $false; $script:RestartRequired = $true
                    Write-Item FAIL $svc.Title 'set to Manual; Windows applies this when it restarts'
                    continue
                }
                Write-Item OK $svc.Title 'was disabled, now Manual after Windows restarts'
                $restartAdvised = $true
                continue
            }
            catch {
                $state = "disabled and could not be changed ($(Format-Brief $_.Exception.Message 120))"
                Write-Log "Could not set $($svc.Name) to Manual: $(Format-ErrorText $_.Exception.Message)" 'WARN' -Quiet
            }
        }
        Write-Log "Service $($svc.Name) ($($svc.Title)) is $state" 'WARN' -Quiet
        if ($svc.Required) {
            $ready = $false
            Write-Item FAIL $svc.Title "$state; Windows needs it for $($svc.Use)"
            continue
        }
        Write-Item WARN $svc.Title "$state; $($svc.Use) will not work"
        $fix = if ($null -ne $start -and -not $FixServices) { ' Run the installer again with -FixServices to set it to Manual.' } else { '' }
        $script:Advisories.Add("$($svc.Title) ($($svc.Name)) is $state, so $($svc.Use) will not work.$fix")
    }
    if ($problems -eq 0) { Write-Item OK 'Services' "all $(@($script:StoreServices).Count) services the Store uses are enabled" }
    if ($restartAdvised -and $ready) { $script:Advisories.Add('Restart Windows after the install: Windows applies the re-enabled services when it starts.') }

    $hives = @('LocalMachine') + @(if (-not $script:IsSystem) { 'CurrentUser' })
    foreach ($policy in $script:StorePolicies) {
        foreach ($hive in $hives) {
            if ($hive -eq 'CurrentUser' -and -not $policy.UserToo) { continue }
            $value = Get-PolicyValue -Hive $hive -Key $policy.Key -Name $policy.Name
            if ($null -eq $value -or [string]$value -ne '1') { continue }
            $where = '{0}\{1}\{2}' -f $(if ($hive -eq 'LocalMachine') { 'HKLM' } else { 'HKCU' }), $policy.Key, $policy.Name
            Write-Log "Policy set: $where = 1" 'WARN' -Quiet
            Write-Item WARN "Policy $($policy.Name)" $policy.Text
            $script:Advisories.Add("A Group Policy $($policy.Text) ($where = 1). Remove it, or ask your administrator, then restart Windows.")
        }
    }
    if ($InstallationType -eq 'Server') {
        Write-Log 'Windows Server is not a tested target' 'WARN' -Quiet
        Write-Item WARN 'Windows Server' 'not a tested target: Microsoft Store may not work'
    }
    return $ready
}

function Get-ClockOffset {
    # Microsoft's time minus this PC's time, from the HTTP Date header of the Store catalog; $null when unavailable.
    param([string] $Uri = 'https://displaycatalog.mp.microsoft.com/')
    $response = $null
    try {
        $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Uri)
        $request.Method = 'HEAD'
        $request.Timeout = 15000
        $request.AllowAutoRedirect = $false
        try { $response = $request.GetResponse() }
        catch {
            # Any HTTP status will do: only the Date header matters.
            $web = $_.Exception
            while ($web -and $web -isnot [Net.WebException]) { $web = $web.InnerException }
            if (-not $web -or -not $web.Response) { throw }
            $response = $web.Response
        }
        $date = $response.Headers['Date']
        if (-not $date) { return $null }
        $server = [DateTime]::Parse($date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal')
        return ($server - [DateTime]::UtcNow)
    }
    catch {
        Write-Log "Clock check skipped: $(Format-ErrorText $_.Exception.Message)" -Quiet
        return $null
    }
    finally { if ($response) { $response.Close() } }
}

function Test-Clock {
    # Reports a Windows clock that is 5 or more minutes off. The downloads themselves do not depend on it: on
    # 2026-11-24 the delivery service accepted requests from a clock 20 minutes fast and one day fast or slow. Sign-in
    # and licenses can, so the user is told to fix the clock.
    $offset = Get-ClockOffset
    if ($null -eq $offset) { return }
    Write-Log ('Clock: this PC differs from Microsoft by {0:N0} seconds' -f $offset.TotalSeconds) -Quiet
    if ([Math]::Abs($offset.TotalMinutes) -lt 5) { return }
    $minutes = [int][Math]::Round([Math]::Abs($offset.TotalMinutes))
    $amount = if ($minutes -ge 120) { '{0:N0} hours' -f ($minutes / 60) } else { "$minutes minutes" }
    $direction = if ($offset.TotalSeconds -gt 0) { 'slow' } else { 'fast' }
    Write-Item WARN 'Windows clock' "$amount $direction"
    $script:Advisories.Add("The Windows clock is $amount $direction. A wrong clock can break Store sign-in and app licenses: turn on 'Set time automatically', or run 'w32tm /resync' as administrator.")
}

function Get-DeploymentErrorCode {
    # The HRESULT of a deployment error, such as "0x80073D06", so that decisions do not depend on the language of the
    # Windows error text. Deployment errors start with "... HRESULT: 0x80073CF0, ..." in every language, and that first
    # code is the deployment result; the exception's own HResult is often a mapped one (a "package could not be opened"
    # error arrives as FileNotFoundException, 0x80070002), so it is only the fallback. $null when there is none.
    param($ErrorRecord)
    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    for ($e = $exception; $e; $e = $e.InnerException) {
        if ([string]$e.Message -match '0x[0-9A-Fa-f]{8}') { return '0x' + $Matches[0].Substring(2).ToUpperInvariant() }
    }
    for ($e = $exception; $e; $e = $e.InnerException) {
        $hr = [int]$e.HResult
        # Facility 0x13 codes (0x8013xxxx) are generic .NET exception types, not a deployment result.
        if ($hr -ne 0 -and (($hr -shr 16) -band 0x1FFF) -ne 0x13) { return ('0x{0:X8}' -f $hr) }
    }
    return $null
}

function Invoke-Winget {
    # Runs winget through its App Execution Alias, the way a user would. Returns the exit code and output, or $null
    # when this account has no winget alias. Throws when Windows refuses to start it (for example without a license).
    param([string[]] $Arguments = @('--version'), [int] $TimeoutSeconds = 60)
    $exe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    # The alias appears shortly after registration.
    for ($wait = 0; $wait -lt 10 -and -not (Test-Path -LiteralPath $exe); $wait++) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    $start = New-Object Diagnostics.ProcessStartInfo $exe
    $start.Arguments = $Arguments -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "winget did not finish within $TimeoutSeconds seconds"
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = (($stdout.Result + ' ' + $stderr.Result) -replace '\s+', ' ').Trim() }
    }
    finally { $process.Dispose() }
}

function Test-WingetCommand {
    # Registration does not prove that winget works: without its license Windows refuses to start it ("No applicable
    # app licenses found"). Run it once, as the user would. Returns $true when it runs.
    $problem = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $result = Invoke-Winget -Arguments '--version'
            if (-not $result) { $problem = 'winget.exe is not available for this user' }
            elseif ($result.ExitCode -eq 0 -and $result.Output -match 'v?\d+(\.\d+)+') {
                Write-Log "winget runs: $($result.Output)" -Quiet
                Write-Item OK "winget $($Matches[0]) runs"
                return $true
            }
            else { $problem = ('winget exited with code 0x{0:X8}: {1}' -f $result.ExitCode, $result.Output) }
        }
        catch { $problem = Format-ErrorText $_.Exception.Message }
        if ($attempt -eq 1) { Start-Sleep -Seconds 3 }
    }
    Write-Log "winget does not run: $problem" 'WARN' -Quiet
    Write-Item WARN 'winget does not run yet' (Format-Brief $problem 200)
    # A missing license was already counted as a failure; do not count its consequence again.
    if (-not $script:WingetLicenseMissing) { Add-Failure "winget does not run: $(Format-Brief $problem 120)" }
    return $false
}
# endregion

# region Diagnostics bundle (-CollectLogs)
function Protect-DiagnosticText {
    # Removes user, computer and domain names and account SIDs, so the bundle can go on a public issue. The collected
    # logs and events can come from other accounts too (a shared offline folder, another user's install), so besides
    # the collecting account's own names it replaces every profile folder name under \Users\ and the account and
    # computer recorded in an installer log, whoever they belong to.
    param([AllowNull()][AllowEmptyString()][string] $Text)
    if (-not $Text) { return $Text }
    $Text = [regex]::Replace($Text, 'S-1-5-21-\d+-\d+-\d+-\d+', '<sid>')
    # Paths first, whole names only. Replacing a name inside a path first would cut it apart: with a profile of
    # C:\Users\Jane, the folder of another account, C:\Users\Jane Smith, would become "%USERPROFILE% Smith" or
    # "\Users\<user> Smith" and keep "Smith" (CodeRabbit review, PR #8).
    $options = [Text.RegularExpressions.RegexOptions]'IgnoreCase, Multiline'
    # 1. This account's profile path, only where it ends: followed by a backslash, a quote or the end of the line.
    if ($env:USERPROFILE -and $env:USERPROFILE.Length -ge 4) {
        $Text = [regex]::Replace($Text, [regex]::Escape($env:USERPROFILE.TrimEnd('\')) + '(?=\\|[\r\n"''<>|]|$)', '%USERPROFILE%', $options)
    }
    # 2. Any other profile folder. Windows' shared profile folders name no one and are kept, but only as a whole folder
    #    name: "Public Smith" is an account. A profile name may contain spaces, so a name at the end of a path, where
    #    nothing marks its end, is replaced up to the end of the line or a quote: that can hide a little of the text
    #    after it, but never leaves part of a name behind.
    $chars = '[^\\\r\n"''<>|*?:]'
    $shared = '(?:Public|Default|Default User|All Users)'
    $Text = [regex]::Replace($Text, '(?<=\\Users\\)(?!' + $shared + '\\)' + $chars + '+(?=\\)', '<user>', $options)
    $Text = [regex]::Replace($Text, '(?<=\\Users\\)(?!' + $chars + '*\\)(?!' + $shared + '(?:[\r\n"''<>|]|$))(?!<user>)' + $chars + '+', '<user>', $options)
    # 3. This account's user, computer and domain names elsewhere in the text.
    foreach ($pair in @(@($env:USERNAME, '<user>'), @($env:COMPUTERNAME, '<computer>'), @($env:USERDOMAIN, '<domain>'))) {
        if (-not $pair[0] -or $pair[0].Length -lt 2) { continue }
        $Text = [regex]::Replace($Text, '(?<![\w-])' + [regex]::Escape($pair[0]) + '(?![\w-])', $pair[1], 'IgnoreCase')
    }
    # The account and computer an installer log recorded, which may be another user's or another PC's.
    $Text = [regex]::Replace($Text, '(?m)^(\[[^\]\r\n]*\] \[\w+\] User\s*: )[^\r\n(]*?(\s*\(SYSTEM[^\r\n]*)?(\r?)$', '$1<domain>\<user>$2$3')
    $Text = [regex]::Replace($Text, '(?m)^(\[[^\]\r\n]*\] \[\w+\] Computer\s*: )[^\r\n]*?(\r?)$', '$1<computer>$2')
    return $Text
}

function Test-Endpoint {
    # One line about whether an HTTPS host answers: any HTTP status counts as reachable.
    param([Parameter(Mandatory)][string] $Uri)
    $response = $null
    try {
        $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Uri)
        $request.Method = 'HEAD'; $request.Timeout = 15000; $request.AllowAutoRedirect = $false
        try { $response = $request.GetResponse() }
        catch {
            $web = $_.Exception
            while ($web -and $web -isnot [Net.WebException]) { $web = $web.InnerException }
            if (-not $web -or -not $web.Response) { throw }
            $response = $web.Response
        }
        return "reachable (HTTP $([int]$response.StatusCode))"
    }
    catch { return "FAILED: $(Format-ErrorText $_.Exception.Message)" }
    finally { if ($response) { $response.Close() } }
}

function Save-Diagnostics {
    # Writes a zip with what a bug report needs and returns the exit code. Each part is collected on its own, so one
    # that fails (no admin rights, a missing event log) is noted in the bundle instead of stopping it.
    param([Parameter(Mandatory)] $OsInfo, [Parameter(Mandatory)][string] $OsName, [Parameter(Mandatory)][int] $Build, [int] $Revision)
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('Store-LTSC-diagnostics-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $staging
    $elevated = Test-IsElevated
    $packageNames = @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.XboxIdentityProvider', 'Microsoft.DesktopAppInstaller', 'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.Native*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.Services.Store.Engagement')
    $parts = [ordered]@{
        'system.txt'       = {
            $info = [ordered]@{
                'Store-LTSC version' = $script:Version
                'Windows'            = "$OsName (build $Build.$Revision)"
                'EditionID'          = $(if ($OsInfo.PSObject.Properties['EditionID']) { $OsInfo.EditionID })
                'InstallationType'   = $(if ($OsInfo.PSObject.Properties['InstallationType']) { $OsInfo.InstallationType })
                'Architecture'       = Get-OsArch
                'PowerShell'         = "$($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition), $([IntPtr]::Size * 8)-bit"
                'Language mode'      = [string]$ExecutionContext.SessionState.LanguageMode
                'Elevated'           = $elevated
                'Running as SYSTEM'  = Test-IsSystemAccount
                'UI culture'         = [string](Get-UICulture).Name
                'Local time'         = (Get-Date).ToString('o')
                'UTC time'           = [DateTime]::UtcNow.ToString('o')
            }
            $offset = Get-ClockOffset
            $info['Clock vs Microsoft'] = if ($null -ne $offset) { '{0:N0} seconds' -f $offset.TotalSeconds } else { 'unknown' }
            foreach ($host_ in @('https://displaycatalog.mp.microsoft.com/', 'https://fe3.delivery.mp.microsoft.com/', 'https://api.github.com/', 'https://github.com/')) { $info["Network $host_"] = Test-Endpoint $host_ }
            $info.GetEnumerator() | ForEach-Object { '{0,-40} {1}' -f $_.Key, $_.Value }
        }
        'services.txt'     = {
            foreach ($svc in $script:StoreServices) {
                $start = Get-ServiceStartValue $svc.Name
                $startText = if ($null -eq $start) { 'missing' } else { switch ($start) { 2 { 'Automatic' } 3 { 'Manual' } 4 { 'DISABLED' } default { "Start=$start" } } }
                $status = try { [string](Get-Service -Name $svc.Name -ErrorAction Stop).Status } catch { 'unknown' }
                '{0,-16} {1,-34} {2,-10} {3}' -f $svc.Name, $svc.Title, $startText, $status
            }
        }
        'policies.txt'     = {
            foreach ($policy in $script:StorePolicies) {
                foreach ($hive in 'LocalMachine', 'CurrentUser') {
                    $value = Get-PolicyValue -Hive $hive -Key $policy.Key -Name $policy.Name
                    '{0}\{1}\{2} = {3}' -f $(if ($hive -eq 'LocalMachine') { 'HKLM' } else { 'HKCU' }), $policy.Key, $policy.Name, $(if ($null -eq $value) { '(not set)' } else { $value })
                }
            }
        }
        'packages-current-user.txt' = {
            $packageNames | ForEach-Object { Get-AppxPackage -Name $_ -ErrorAction Stop } | Sort-Object Name, Version |
                Format-Table Name, Version, Architecture, Status, IsFramework, SignatureKind -AutoSize | Out-String -Width 250
        }
        'packages-all-users.txt' = {
            if (-not $elevated) { 'Needs administrator rights.'; return }
            # Per-user detail is summarised by state: other accounts' names stay out of the bundle.
            $packageNames | ForEach-Object { Get-AppxPackage -AllUsers -Name $_ -ErrorAction Stop } | Sort-Object Name, Version | ForEach-Object {
                $states = @($_.PackageUserInformation | Group-Object { [string]$_.InstallState } | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }) -join ', '
                '{0,-50} {1,-18} {2,-8} {3}' -f $_.Name, $_.Version, $_.Architecture, $states
            }
        }
        'packages-provisioned.txt' = {
            if (-not $elevated) { 'Needs administrator rights.'; return }
            Get-AppxProvisionedPackage -Online -ErrorAction Stop | Sort-Object DisplayName | ForEach-Object { '{0,-50} {1,-18} {2}' -f $_.DisplayName, $_.Version, $_.PackageName }
        }
        'winget.txt'       = {
            $result = Invoke-Winget -Arguments '--version' -TimeoutSeconds 30
            if (-not $result) { 'winget.exe is not available for this user' } else { "exit code: 0x{0:X8}`r`noutput: {1}" -f $result.ExitCode, $result.Output }
        }
        'events-appx-deployment.txt' = {
            $filter = @{ LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-7) }
            Get-WinEvent -FilterHashtable $filter -MaxEvents 200 -ErrorAction Stop | ForEach-Object {
                '[{0:yyyy-MM-dd HH:mm:ss}] {1} {2}: {3}' -f $_.TimeCreated, $_.LevelDisplayName, $_.Id, (($_.Message -replace '\s+', ' ').Trim())
            }
        }
    }
    Write-Host ''
    Write-Host '  Collecting diagnostics for a bug report' -ForegroundColor Cyan
    # One try/finally around everything that writes to the staging folder, so no failure leaves it behind.
    try {
        foreach ($part in $parts.GetEnumerator()) {
            Show-Activity -Text 'Collecting diagnostics' -Detail $part.Key
            $text = try { (& $part.Value | Out-String -Width 250) } catch { "Unavailable: $(Format-ErrorText $_.Exception.Message)" }
            if (-not $text.Trim()) { $text = '(nothing found)' }
            Set-Content -LiteralPath (Join-Path $staging $part.Key) -Value (Protect-DiagnosticText $text) -Encoding UTF8
            Write-StatusLine 'OK' $part.Key
        }
        # The newest installer logs from every place a run writes them. A log that cannot be read (another run still
        # writing it, no permission) is noted in the bundle instead of stopping the collection.
        $logDirs = @((Join-Path ([IO.Path]::GetTempPath()) 'StoreInstall-Logs'), $LogDir, $(if ($WorkDir) { Join-Path $WorkDir 'Logs' })) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique
        $logs = @($logDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'StoreInstall-*.log' -File -ErrorAction SilentlyContinue } | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
        $copied = 0
        if ($logs.Count -gt 0) {
            $null = New-Item -ItemType Directory -Path (Join-Path $staging 'logs')
            foreach ($log in $logs) {
                try { $text = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction Stop; $copied++ }
                catch { $text = "Unreadable: $(Format-ErrorText $_.Exception.Message)" }
                Set-Content -LiteralPath (Join-Path $staging "logs\$($log.Name)") -Value (Protect-DiagnosticText $text) -Encoding UTF8
            }
        }
        Write-StatusLine $(if ($copied -eq $logs.Count) { 'OK' } else { 'WARN' }) "installer logs: $copied$(if ($copied -lt $logs.Count) { " of $($logs.Count) readable" })"
        Clear-LiveLine

        # -LogDir only when the user gave it: a relaunch does not fill it in for -CollectLogs (Invoke-Relaunch).
        $desktop = [Environment]::GetFolderPath('Desktop')
        $outDir = if ($LogDir) { $LogDir } elseif ($desktop -and -not (Test-IsSystemAccount) -and (Test-Path -LiteralPath $desktop -PathType Container)) { $desktop } else { Join-Path ([IO.Path]::GetTempPath()) 'StoreInstall-Logs' }
        if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
        $zip = Join-Path $outDir "Store-LTSC-diagnostics-$stamp.zip"
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force
    }
    catch {
        Clear-LiveLine
        Write-StatusLine 'FAIL' "Could not save the diagnostics: $(Format-ErrorText $_.Exception.Message)"
        return 7
    }
    finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ''
    Write-Host "  Diagnostics saved: $zip" -ForegroundColor Green
    Write-Host '  User, computer and domain names are replaced with placeholders. Look through the files, then attach' -ForegroundColor DarkGray
    Write-Host '  the zip to an issue: https://github.com/Softhe/Store-LTSC/issues/new/choose' -ForegroundColor DarkGray
    if (-not $elevated) { Write-Host '  Without administrator rights, the all-users and provisioned package lists are missing.' -ForegroundColor Yellow }
    Write-Host ''
    $script:Completed = $true
    Restore-Console
    return 0
}
# endregion

# region Online download (Microsoft Store delivery service)
$script:Fe3Url = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$script:WuNs = 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService'

function Initialize-Network {
    # TLS 1.2 for older .NET defaults; use the system proxy with the current user's credentials. Both are
    # session-wide .NET settings, so the previous values are kept and put back when the run ends.
    $proxy = [Net.WebRequest]::DefaultWebProxy
    $script:NetworkState = @{
        Protocol         = [Net.ServicePointManager]::SecurityProtocol
        Proxy            = $proxy
        ProxyCredentials = $(if ($proxy) { $proxy.Credentials })
    }
    # 0 is SystemDefault: Windows already negotiates TLS 1.2 or later, so leave it alone.
    if ([int][Net.ServicePointManager]::SecurityProtocol -ne 0) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    if ($proxy) { $proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
}

function Test-PermanentWebError {
    # An HTTP client error (4xx, except 408 Request Timeout and 429 Too Many Requests) gives the same answer on a retry.
    param($Exception)
    for ($e = $Exception; $e; $e = $e.InnerException) {
        if (-not $e.PSObject.Properties['Response'] -or -not $e.Response -or -not $e.Response.PSObject.Properties['StatusCode']) { continue }
        $status = [int]$e.Response.StatusCode
        return ($status -ge 400 -and $status -lt 500 -and @(408, 429) -notcontains $status)
    }
    return $false
}

function Invoke-WithRetry {
    # Retries timeouts, connection failures and server errors. A permanent HTTP client error fails at once, unless
    # -RetryAll is given (package downloads: each attempt asks for a fresh download address).
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $What,
        [int] $Attempts = 3,
        [switch] $RetryAll
    )
    for ($i = 1; ; $i++) {
        try { return (& $Action) }
        catch {
            if ($i -ge $Attempts) { throw "$What failed after $Attempts attempts: $($_.Exception.Message)" }
            if (-not $RetryAll -and (Test-PermanentWebError $_.Exception)) { throw "$What failed: $($_.Exception.Message)" }
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
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Package)
    if ((Get-Item -LiteralPath $Path).Length -ne $Package.Size) { return 'size mismatch' }
    $algo, $b64 = if ($Package.Sha256) { 'SHA256', $Package.Sha256 } else { 'SHA1', $Package.Sha1 }
    $expected = [BitConverter]::ToString([Convert]::FromBase64String($b64)) -replace '-', ''
    if ((Get-FileHash -LiteralPath $Path -Algorithm $algo).Hash -ne $expected) { return "$algo mismatch" }
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
        return "signature not valid Microsoft ($($sig.Status): $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject }))"
    }
    return $null
}

function Save-PackageDownload {
    # Streams one file to disk in small blocks, so progress can be shown and Ctrl+C is answered promptly.
    # A partial file left by an earlier attempt is resumed. The transfer stops when no data arrives for
    # StallSeconds or when it exceeds TimeoutSeconds in total.
    param([string] $Url, [string] $Path, [int] $TimeoutSeconds = 1800, [int] $StallSeconds = 60, [scriptblock] $OnProgress)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $wait = [Math]::Max(1, [Math]::Min($StallSeconds, $TimeoutSeconds))
    $existing = [long]0
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $existing = (Get-Item -LiteralPath $Path).Length }
    $timeoutError = {
        if (($watch.Elapsed.TotalSeconds + 0.5) -ge $TimeoutSeconds) { "Download exceeded the $TimeoutSeconds second time limit" }
        else { "Download stalled: no data received for $wait seconds" }
    }
    $findWebException = {
        param($exception)
        while ($exception -and $exception -isnot [Net.WebException]) { $exception = $exception.InnerException }
        $exception
    }

    $request = [Net.HttpWebRequest][Net.WebRequest]::Create([uri]$Url)
    $request.Timeout = $wait * 1000
    $request.ReadWriteTimeout = $wait * 1000
    if ($existing -gt 0) { $request.AddRange($existing) }
    $response = $null; $source = $null; $target = $null
    try {
        try { $response = $request.GetResponse() }
        catch {
            $web = & $findWebException $_.Exception
            if ($web -and $web.Status -eq [Net.WebExceptionStatus]::Timeout) { throw (& $timeoutError) }
            if ($web -and $web.Response -and [int]$web.Response.StatusCode -eq 416) {
                # The server rejected the resume position: start this file again on the next attempt.
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                throw 'The server rejected the partial download; starting again'
            }
            throw
        }
        $append = $existing -gt 0 -and [int]$response.StatusCode -eq 206
        if (-not $append) { $existing = [long]0 }
        $total = if ($response.ContentLength -ge 0) { $existing + $response.ContentLength } else { [long]-1 }
        $source = $response.GetResponseStream()
        $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $target = New-Object IO.FileStream($Path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 262144
        $received = $existing
        $lastReport = [long]-1000
        while ($true) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Download exceeded the $TimeoutSeconds second time limit" }
            try { $read = $source.Read($buffer, 0, $buffer.Length) }
            catch {
                $web = & $findWebException $_.Exception
                if ($web -and $web.Status -eq [Net.WebExceptionStatus]::Timeout) { throw (& $timeoutError) }
                throw
            }
            if ($read -le 0) { break }
            $target.Write($buffer, 0, $read)
            $received += $read
            if ($OnProgress -and ($watch.ElapsedMilliseconds - $lastReport) -ge 100) {
                $lastReport = $watch.ElapsedMilliseconds
                & $OnProgress $received $total
            }
        }
        if ($OnProgress) { & $OnProgress $received $total }
    }
    finally {
        if ($target) { $target.Dispose() }
        if ($source) { try { $request.Abort() } catch { }; $source.Dispose() }
        if ($response) { $response.Close() }
    }
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
    $label = Format-PackageLabel $p.Identity
    $title = ($label -split '\s{2,}')[0]
    $size = '{0,8:N1} MB' -f ($p.Size / 1MB)
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Show-Activity -Text $title -Detail 'checking the copy already downloaded'
        if (-not (Test-PackageFile -Path $target -Package $p)) {
            Write-Log "Already downloaded (verified): $([IO.Path]::GetFileName($target))" -Quiet
            Write-Item OK $label "$size, already downloaded"
            return (Get-Item -LiteralPath $target)
        }
    }

    # One temporary file per package: a retry resumes it instead of starting again.
    $part = Join-Path $Destination (([guid]::NewGuid().ToString('N')) + '.part' + $p.Extension)
    $totalMb = $p.Size / 1MB
    $meter = @{ Timer = $null; First = [long]0 }
    $onProgress = {
        param($received, $total)
        if (-not $meter.Timer) { $meter.Timer = [Diagnostics.Stopwatch]::StartNew(); $meter.First = $received }
        $seconds = $meter.Timer.Elapsed.TotalSeconds
        $detail = @('{0,5:N1}/{1:N1} MB' -f ($received / 1MB), $totalMb)
        if ($seconds -ge 1) {
            $rate = ($received - $meter.First) / $seconds
            if ($rate -gt 0) {
                $left = [TimeSpan]::FromSeconds([Math]::Min(359999, [Math]::Max(0, ($p.Size - $received) / $rate)))
                $detail += '{0:N1} MB/s' -f ($rate / 1MB)
                $detail += '{0} left' -f (Format-Clock $left)
            }
        }
        Show-Activity -Text $title -Fraction $(if ($p.Size -gt 0) { $received / $p.Size } else { -1 }) -Detail $detail
    }
    try {
        $null = Invoke-WithRetry -What "Download of $($p.Moniker)" -RetryAll -Action {
            # URLs are short-lived; request a fresh one per attempt.
            Show-Activity -Text $title -Detail 'connecting'
            $url = Get-Fe3FileUrl -Package $p -DeviceAttributes $DeviceAttributes
            Write-Log ('Downloading {0} ({1:N1} MB)' -f [IO.Path]::GetFileName($target), $totalMb) -Quiet
            $meter.Timer = $null
            Save-PackageDownload -Url $url -Path $part -TimeoutSeconds $DownloadTimeoutSeconds -OnProgress $onProgress
            Show-Activity -Text $title -Fraction 1 -Detail 'verifying hash and signature'
            # Never resume from a file that failed verification, or that could not be verified.
            try { $problem = Test-PackageFile -Path $part -Package $p }
            catch { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue; throw }
            if ($problem) {
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                throw "verification failed: $problem"
            }
            Move-Item -LiteralPath $part -Destination $target -Force
        }
    } finally { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    Write-Log "Downloaded + verified (hash, Microsoft signature): $([IO.Path]::GetFileName($target))" -Quiet
    Write-Item OK $label $size
    return (Get-Item -LiteralPath $target)
}

function Save-OnlinePackages {
    # Resolves, selects and downloads packages for the given families. Returns the downloaded FileInfo objects.
    param(
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string[]] $Families,
        [Parameter(Mandatory)][string] $OsArch,
        [Parameter(Mandatory)][int] $Build,
        [int] $Revision = 0,
        # Download-only: the folder must hold every framework the apps declare, so one the service does not offer is a
        # failure. An install can still use a framework the PC already has.
        [switch] $RequireComplete
    )
    Initialize-Network
    Show-Activity -Text 'Microsoft Store catalog' -Detail 'checking the clock'
    Test-Clock
    Show-Activity -Text 'Microsoft Store catalog' -Detail 'connecting'
    $attrs = Get-Fe3DeviceAttributes -OsArch $OsArch -Build $Build
    $cookie = Get-Fe3Cookie

    $offered = @{}
    $lookupFailed = @{}
    foreach ($fam in $Families) {
        try {
            Show-Activity -Text 'Microsoft Store catalog' -Fraction ([array]::IndexOf($Families, $fam) / $Families.Count) -Detail "looking up $(Format-AppTitle ($fam -replace '_.*$'))"
            $cat = Get-WuCategoryId -PackageFamilyName $fam
            $list = @(Get-Fe3PackageList -CategoryId $cat -Cookie $cookie -DeviceAttributes $attrs)
            Write-Log "Catalog: $fam -> category $cat, $($list.Count) package(s) offered" -Quiet
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
        if ($rank -gt 0) { $p | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -PassThru -Force }
    }

    # Frameworks: newest version per name+arch. Apps: every offered version, best first (highest Store PackageRank,
    # then newest version, best arch). The service offers the same list to every Windows build, so an app's
    # Windows requirement is only known once its manifest has been read.
    $appCandidates = @{}
    $fwPkgs = New-Object System.Collections.Generic.List[object]
    foreach ($g in ($usable | Group-Object { $_.Identity.Name })) {
        if ($g.Group | Where-Object IsFramework) {
            [void]$script:OnlineFrameworkNames.Add($g.Name)
            foreach ($a in ($g.Group | Group-Object { $_.Identity.Arch })) {
                $fwPkgs.Add(($a.Group | Sort-Object { $_.Identity.Version } -Descending | Select-Object -First 1))
            }
        }
        else {
            $sorted = @($g.Group | Sort-Object @{ Expression = { $_.PackageRank }; Descending = $true },
                @{ Expression = { $_.Identity.Version }; Descending = $true },
                @{ Expression = { $_.Rank }; Descending = $true })
            $appCandidates[[string]$sorted[0].Identity.Family] = $sorted
        }
    }
    if (-not $appCandidates.ContainsKey($script:StoreFamily)) {
        throw 'The Store service did not offer a usable Microsoft.WindowsStore package'
    }
    Write-Log "Offered: $($appCandidates.Count) app(s), $($fwPkgs.Count) framework package(s); download folder: $Destination" -Quiet
    foreach ($p in @($appCandidates.Values | ForEach-Object { $_ }) + $fwPkgs.ToArray() | Sort-Object Moniker) { Write-Log ('  {0}{1} ({2:N1} MB)' -f $p.Moniker, $p.Extension, ($p.Size / 1MB)) -Quiet }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force
    }

    # Remove stale metadata first so an interrupted replacement cannot look complete.
    $manifestPath = Join-Path $Destination 'store-packages.json'
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    $downloaded = New-Object System.Collections.Generic.List[object]
    $hashes = @{}
    $pendingManifests = New-Object System.Collections.Generic.Queue[object]
    $missing = New-Object System.Collections.Generic.List[string]

    # Apps in the order requested (Microsoft Store first). When the best version needs a newer Windows than this
    # machine runs, fall back to the next version the service offers.
    foreach ($fam in $Families) {
        $chosen = $null
        foreach ($p in @(if ($appCandidates.ContainsKey($fam)) { $appCandidates[$fam] })) {
            $file = Save-OnlinePackage -Package $p -Destination $Destination -DeviceAttributes $attrs
            $meta = Get-PackageMetadata -Path $file.FullName -OsArch $OsArch -Build $Build -Revision $Revision
            if ($meta.Supported -and (Get-ArchRank -Arch $meta.Arch -OsArch $OsArch -Build $Build) -gt 0) {
                $chosen = [pscustomobject]@{ Package = $p; File = $file; Metadata = $meta }
                break
            }
            Write-Log "$($p.Moniker)$($p.Extension) does not support Windows build $Build.$Revision on $OsArch; trying an older version" 'WARN' -Console "$($p.Identity.Name) $($p.Identity.Version) needs a newer Windows version; trying an older one"
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
        if (-not $chosen) {
            if ($fam -eq $script:StoreFamily) { throw "The Store service offers no Microsoft Store version that supports Windows build $Build.$Revision on $OsArch" }
            $missing.Add($fam)
            Add-Failure "Requested app unavailable: $fam"
            Write-Log "Requested app unavailable: $fam. This run is incomplete." 'WARN'
            continue
        }
        $downloaded.Add($chosen.File)
        $hashes[$chosen.File.Name] = $chosen.Package.Sha256
        $pendingManifests.Enqueue($chosen)
    }

    # The service offers frameworks for every app version. Download only the frameworks the chosen apps'
    # manifests declare (and what those frameworks declare in turn).
    $neededFw = New-Object System.Collections.Generic.List[object]
    # Declared frameworks the service does not offer (name, minimum version, architecture). Installing can still work
    # when the PC already has them; an offline folder (-RequireComplete) is incomplete without them.
    $unsatisfied = [ordered]@{}
    while ($pendingManifests.Count -gt 0) {
        $item = $pendingManifests.Dequeue()
        foreach ($dep in $item.Metadata.Dependencies) {
            $expectedFamily = if ($dep.Publisher) { $dep.Name + '_' + (Get-PublisherId $dep.Publisher) } else { $null }
            $matching = @($fwPkgs | Where-Object { $_.Identity.Name -eq $dep.Name -and (-not $expectedFamily -or $_.Identity.Family -eq $expectedFamily) -and ($_.Identity.Arch -eq 'neutral' -or $_.Identity.Arch -eq $dep.Arch) -and $_.Identity.Version -ge $dep.MinVersion })
            if ($matching.Count -eq 0) {
                $key = '{0} {1} or newer ({2})' -f $dep.Name, $dep.MinVersion, $dep.Arch
                if (-not $unsatisfied.Contains($key)) {
                    $unsatisfied[$key] = $true
                    Write-Log "The service offers no package for $key, which $($item.Package.Identity.Name) declares" 'WARN' -Quiet:(-not $RequireComplete)
                    if ($RequireComplete) { Add-Failure "Framework not offered: $key" }
                }
            }
            foreach ($fw in $matching) {
                if ($neededFw.Contains($fw)) { continue }
                $neededFw.Add($fw)
                $fwFile = Save-OnlinePackage -Package $fw -Destination $Destination -DeviceAttributes $attrs
                $downloaded.Add($fwFile)
                $hashes[$fwFile.Name] = $fw.Sha256
                $pendingManifests.Enqueue([pscustomobject]@{ Package = $fw; File = $fwFile; Metadata = (Get-PackageMetadata -Path $fwFile.FullName -OsArch $OsArch -Build $Build -Revision $Revision) })
            }
        }
    }
    Clear-LiveLine
    foreach ($fw in $fwPkgs) {
        if (-not $neededFw.Contains($fw)) { Write-Log "Not downloading $($fw.Moniker)$($fw.Extension): no requested app declares it" -Quiet }
    }
    $totalMb = [math]::Round(($downloaded | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Write-Log "Downloaded $($downloaded.Count) package(s), $totalMb MB" -Console ("{0} package(s), {1:N1} MB, hashes and Microsoft signatures verified" -f $downloaded.Count, $totalMb)
    $manifest = [ordered]@{
        SchemaVersion = 1
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        OsArch = $OsArch
        Build = $Build
        RequestedFamilies = @($Families)
        MissingFamilies = @($missing)
        MissingDependencies = @($unsatisfied.Keys)
        Files = @($downloaded | ForEach-Object {
            # The published SHA-256 was just verified against the file; hash again only when the service gave SHA-1.
            $sha256 = if ($hashes[$_.Name]) { [BitConverter]::ToString([Convert]::FromBase64String($hashes[$_.Name])) -replace '-', '' } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
            [ordered]@{ Name = $_.Name; Size = $_.Length; Sha256 = $sha256 }
        })
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
        Write-Host 'ERROR: PowerShell FullLanguage mode is required.' -ForegroundColor Red
        return 3
    }
    Initialize-Console

    # -DownloadOnly installs nothing, so it needs neither admin rights nor a supported build.
    if ($DownloadOnly -and $Source -eq 'Local') {
        Write-StatusLine 'FAIL' '-DownloadOnly cannot be combined with -Source Local.'
        return 7
    }
    if (($TargetBuild -or $TargetArch) -and -not $DownloadOnly) {
        Write-StatusLine 'FAIL' '-TargetBuild and -TargetArch only work with -DownloadOnly.'
        return 7
    }
    if ($TargetArch -and @('x64', 'arm64', 'x86') -notcontains $TargetArch) {
        Write-StatusLine 'FAIL' "-TargetArch must be x64, arm64 or x86, not '$TargetArch'."
        return 7
    }
    if ($TargetBuild -and $TargetBuild -lt 10240) {
        Write-StatusLine 'FAIL' "-TargetBuild must be a Windows 10 or 11 build number such as 19044, not $TargetBuild."
        return 7
    }
    if ($CollectLogs -and ($DownloadOnly -or $FixServices)) {
        Write-StatusLine 'FAIL' '-CollectLogs installs nothing and cannot be combined with -DownloadOnly or -FixServices.'
        return 7
    }

    # Resolve paths before any relaunch, which may start in another directory.
    # WorkDir is empty when run via irm | iex; local packages then come from the current folder only with -Source Local.
    if (-not $WorkDir -and $Source -eq 'Local') { $WorkDir = (Get-Location).ProviderPath }
    $WorkDir = Resolve-UserPath $WorkDir
    $LogDir = Resolve-UserPath $LogDir
    $DownloadDir = Resolve-UserPath $DownloadDir

    # -CollectLogs asks for administrator rights too (they show the provisioned packages), but works without them.
    if (-not $DownloadOnly -and -not (Test-IsElevated)) {
        if (-not (Test-CanPromptForElevation)) {
            if (-not $CollectLogs) {
                Write-StatusLine 'FAIL' 'Run this script as Administrator.'
                return 1
            }
        }
        else {
            try { return (Invoke-Relaunch -Elevate) }
            catch {
                if (-not $CollectLogs) {
                    Write-StatusLine 'FAIL' "Administrator rights are required ($($_.Exception.Message))."
                    return 1
                }
                Write-StatusLine 'WARN' 'Collecting without administrator rights; some package lists will be missing.'
            }
        }
    }

    # Appx/DISM cmdlets need 64-bit Windows PowerShell: relaunch from 32-bit hosts or PowerShell 7.
    if (([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) -or $PSVersionTable.PSEdition -eq 'Core') {
        return (Invoke-Relaunch)
    }

    # Windows PowerShell started by PowerShell 7 (a terminal, a script, Start-Process) can carry its module path.
    if ($env:PSModulePath -match '\\PowerShell\\|\\Microsoft\.PowerShell_') {
        $script:SavedModulePath = $env:PSModulePath
        $env:PSModulePath = Get-WindowsPowerShellModulePath $env:PSModulePath
    }

    $osVersionInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$osVersionInfo.CurrentBuildNumber
    $revision = 0
    if ($osVersionInfo.PSObject.Properties['UBR']) { $revision = [int]$osVersionInfo.UBR }
    # "Windows 10 Enterprise LTSC 2021, 21H2". Windows 11 still reports "Windows 10" in ProductName.
    $osName = if ($osVersionInfo.PSObject.Properties['ProductName']) { [string]$osVersionInfo.ProductName } else { 'Windows' }
    if ($build -ge 22000) { $osName = $osName -replace '^Windows 10', 'Windows 11' }
    if ($osVersionInfo.PSObject.Properties['DisplayVersion'] -and $osVersionInfo.DisplayVersion) { $osName += ", $($osVersionInfo.DisplayVersion)" }
    # Diagnostics work on any build, including the unsupported ones people report problems from.
    if ($CollectLogs) { return (Save-Diagnostics -OsInfo $osVersionInfo -OsName $osName -Build $build -Revision $revision) }
    if (-not $DownloadOnly -and $build -lt 19041) {
        Write-StatusLine 'FAIL' "Windows build 19041 or later is required (this is build $build)."
        return 2
    }

    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
            Write-StatusLine 'FAIL' "WorkDir not found: $WorkDir"
            return 7
        }
    }

    $script:IsSystem = Test-IsSystemAccount
    $script:DoProvision = -not $NoProvision
    if ($script:IsSystem -and -not $script:DoProvision -and -not $DownloadOnly) {
        Write-StatusLine 'FAIL' '-NoProvision cannot be used as SYSTEM (per-user install is not possible for SYSTEM).'
        return 7
    }

    # Log dir: requested/default location, falling back to %TEMP% (e.g. packages on read-only media)
    $tempLogDir = Join-Path ([IO.Path]::GetTempPath()) 'StoreInstall-Logs'
    $logStamp = 'StoreInstall-{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $logCandidates = @(
        $(if ($LogDir) { $LogDir } elseif ($WorkDir) { Join-Path $WorkDir 'Logs' } else { $tempLogDir }),
        $tempLogDir
    ) | Select-Object -Unique
    foreach ($dir in $logCandidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $dir -Force
            }
            $candidate = Join-Path $dir "$logStamp.log"
            if (Test-Path -LiteralPath $candidate) { $candidate = Join-Path $dir ('{0}-{1}.log' -f $logStamp, [guid]::NewGuid().ToString('N').Substring(0, 6)) }
            $null = New-Item -ItemType File -Path $candidate
            $script:LogFile = $candidate
            break
        }
        catch {
            Write-StatusLine 'WARN' "Cannot write log in ${dir}: $($_.Exception.Message)"
        }
    }

    $osArch = Get-OsArch
    # A download for another machine (-TargetBuild/-TargetArch) picks packages for that machine instead.
    $pkgArch = if ($TargetArch) { $TargetArch } else { $osArch }
    $pkgBuild = if ($TargetBuild) { $TargetBuild } else { $build }
    $pkgRevision = if ($TargetBuild) { 0 } else { $revision }
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

    Write-Log '==== Microsoft Store unattended install starting ====' -Quiet
    Write-Log "Version   : Store-LTSC $script:Version" -Quiet
    Write-Log "Work dir  : $(if ($WorkDir) { $WorkDir } else { '(none)' })" -Quiet
    Write-Log "Log file  : $(if ($script:LogFile) { $script:LogFile } else { '(console only)' })" -Quiet
    Write-Log "User      : $env:USERDOMAIN\$env:USERNAME$(if ($script:IsSystem) { ' (SYSTEM: provisioning only)' })" -Quiet
    Write-Log "Computer  : $env:COMPUTERNAME" -Quiet
    Write-Log "Build     : $build.$revision" -Quiet
    Write-Log "OS arch   : $osArch (PROCESSOR_ARCHITECTURE=$($env:PROCESSOR_ARCHITECTURE), W6432=$($env:PROCESSOR_ARCHITEW6432))" -Quiet
    if ($TargetBuild -or $TargetArch) { Write-Log "Target    : build $pkgBuild, $pkgArch (packages for another machine)" -Quiet }
    if ($FixServices) { Write-Log 'FixServices: True' -Quiet }
    Write-Log "Source    : $(if ($online) { 'Online (Microsoft Store delivery service)' } else { 'Local (work dir)' })$(if ($Source -eq 'Auto') { ' [auto]' })" -Quiet
    Write-Log "Provision : $($script:DoProvision -and -not $DownloadOnly)" -Quiet
    Write-Log "SkipWinget: $([bool]$SkipWinget)" -Quiet

    $script:LicenseDirs = @($WorkDir | Where-Object { $_ })

    $families = @($script:StoreFamily) + $script:OptionalFamilies
    if (-not $SkipWinget) { $families += $script:WingetFamily }

    $title = "Microsoft Store installer for Windows LTSC $script:Version"
    Write-Host ''
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ('  ' + ($script:Glyph.Rule * $title.Length)) -ForegroundColor DarkCyan
    $mode = if ($DownloadOnly) { 'Download only (nothing is installed)' }
        elseif ($script:IsSystem) { 'New users (running as SYSTEM: provisioning only)' }
        elseif (-not $script:DoProvision) { 'This user only' }
        else { 'This user and new users' }
    foreach ($field in @(
            @('Windows', "$osName (build $build.$revision, $osArch)"),
            $(if ($TargetBuild -or $TargetArch) { ,@('Target', "build $pkgBuild, $pkgArch (packages for another machine)") }),
            @('Account', "$env:USERDOMAIN\$env:USERNAME"),
            @('Source', $(if ($online) { 'Microsoft Store delivery service (online)' } else { "Local folder: $WorkDir" })),
            @('Install', $mode),
            @('Apps', (($families | ForEach-Object { $script:AppTitles[$_ -replace '_.*$'] }) -join ', ')),
            @('Log', $(if ($script:LogFile) { $script:LogFile } else { '(console only)' })))) {
        if (-not $field) { continue }   # the Target line is only there for a download for another machine
        Write-Parts @(@(('    {0,-10}' -f $field[0]), 'DarkGray'), @($field[1], $null))
    }
    # Sections are numbered: check Windows, get the packages, install frameworks, install apps, verify.
    $script:StepNumber = 0
    $script:StepTotal = if ($DownloadOnly) { 1 } else { 5 }

    if (-not $DownloadOnly) {
        Write-Section 'Checking Windows'
        $installationType = if ($osVersionInfo.PSObject.Properties['InstallationType']) { [string]$osVersionInfo.InstallationType } else { '' }
        if (-not (Invoke-SystemReadiness -InstallationType $installationType)) {
            $fixHint = if ($script:RestartRequired) { 'Restart Windows, then run the installer again.' }
                elseif ($FixServices) { 'A required service could not be re-enabled. Set it to Manual in services.msc, restart Windows and run the installer again.' }
                else { 'Run the installer again with -FixServices to set the disabled services to Manual.' }
            return (Complete-Run 9 'Windows is not ready for app installation' $fixHint)
        }
    }

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

        Write-Section 'Downloading packages from Microsoft'
        try {
            $all = @(Save-OnlinePackages -Destination $pkgDir -Families $families -OsArch $pkgArch -Build $pkgBuild -Revision $pkgRevision -RequireComplete:$DownloadOnly)
        }
        catch {
            Clear-LiveLine
            Write-Log "Download FAILED: $($_.Exception.Message)" 'ERROR'
            Write-Log 'Check internet access to displaycatalog.mp.microsoft.com, fe3.delivery.mp.microsoft.com and *.dl.delivery.mp.microsoft.com (proxy/firewall), and that the Windows clock and time zone are right.' 'ERROR'
            return (Complete-Run 8 'Download failed')
        }

        # winget needs App Installer's license, which the Store service does not hand out (see Save-WingetLicense).
        # A download-only folder keeps it for the offline install. A license already beside the script is used
        # instead of downloading one, and copied into the package folder so that folder is complete on its own.
        $wingetDownloaded = @($all | Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*' }).Count -gt 0
        if ($wingetDownloaded -and ($DownloadOnly -or $script:DoProvision)) {
            $localWingetLicense = Find-License -PackagePath (Join-Path $pkgDir 'none') -Identity ([pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; Family = $script:WingetFamily })
            if ($localWingetLicense) { $null = Copy-LicenseToFolder -Path $localWingetLicense -Destination $pkgDir -Family $script:WingetFamily }
            else { $null = Save-WingetLicense -Destination $pkgDir }
        }
        Clear-LiveLine

        if ($DownloadOnly) {
            Write-Log "Downloaded $($all.Count) package(s) to $pkgDir" -Quiet
            $hint = "Folder: $pkgDir`n  Install later with: -Source Local -WorkDir `"$pkgDir`""
            if ($script:FailCount -gt 0) { return (Complete-Run 5 'Download set is incomplete' $hint) }
            return (Complete-Run 0 'Packages downloaded' $hint)
        }
    }
    else {
        Write-Section 'Checking local packages'
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
            Write-Log 'Unblocked files in work directory (Mark-of-the-Web)' -Quiet
        }
    }

    if ($all.Count -eq 0) {
        Write-Log 'No Appx/Msix/Bundle packages found.' 'ERROR'
        return (Complete-Run 7)
    }
    Write-Log "Found $($all.Count) package file(s)" -Quiet:$online

    $frameworks = New-Object System.Collections.Generic.List[object]
    $store = $null
    $purchase = $null
    $xboxId = $null
    $winget = $null

    foreach ($f in $all) {
        Show-Activity -Text 'Reading packages' -Detail $f.Name
        try { $id = Get-PackageMetadata -Path $f.FullName -OsArch $osArch -Build $build -Revision $revision }
        catch { Write-Log "Cannot read package '$($f.Name)': $($_.Exception.Message)" 'ERROR'; return (Complete-Run 4) }
        if (-not $id.Supported) { Write-Log "Skipping package requiring a newer Windows version: $($f.Name)" 'WARN'; continue }
        $rank = Get-ArchRank -Arch $id.Arch -OsArch $osArch -Build $build
        if ($rank -eq 0) { Write-Log "Skipping package (arch '$($id.Arch)' not usable on $osArch build $build): $($f.Name)"; continue }
        $pkg = [pscustomobject]@{ File = $f; Identity = $id; Rank = $rank }

        if ($id.IsFramework -or (Test-IsFrameworkPackage -Name $id.Name)) { $frameworks.Add($pkg); continue }

        switch ($id.Name) {
            'Microsoft.WindowsStore'         { $store    = Select-NewerPackage $store $pkg; continue }
            'Microsoft.StorePurchaseApp'     { $purchase = Select-NewerPackage $purchase $pkg; continue }
            'Microsoft.XboxIdentityProvider' { $xboxId   = Select-NewerPackage $xboxId $pkg; continue }
            'Microsoft.DesktopAppInstaller'  { $winget   = Select-NewerPackage $winget $pkg; continue }
            # Only the Store set is installed: an unrelated package that happens to share the folder is left alone.
            default                          { Write-Item SKIP (Format-PackageLabel $id) 'not part of the Store set, ignored' }
        }
    }
    Clear-LiveLine

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

    Write-Log "Store               : $($store.File.Name)" -Quiet
    Write-Log ('PurchaseApp         : {0}' -f $(if ($purchase) { $purchase.File.Name } else { '(not present)' })) -Quiet
    Write-Log ('XboxIdentityProvider: {0}' -f $(if ($xboxId) { $xboxId.File.Name } else { '(not present)' })) -Quiet
    if ($winget -and $SkipWinget) {
        Write-Log 'DesktopAppInstaller : present but skipped (-SkipWinget)' -Quiet
        $winget = $null
    }
    else {
        Write-Log ('DesktopAppInstaller : {0}' -f $(if ($winget) { $winget.File.Name } else { '(not present)' })) -Quiet
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
        $apps = @(@($store, $purchase, $xboxId, $winget) | Where-Object { $null -ne $_ })
        $fwCandidates = @(Select-RequiredFramework -Frameworks $fwCandidates -Applications $apps)
        $sortedFw = @(Get-DependencyInstallOrder -Frameworks $fwCandidates -Applications $apps)
    }
    catch { Write-Log $_.Exception.Message 'ERROR'; return (Complete-Run 4) }
    if (-not $online) {
        Write-Log "Selected $($apps.Count) app(s) and $($sortedFw.Count) framework(s)" -Console "$($apps.Count) app(s) and $($sortedFw.Count) framework(s) ready to install"
    }

    # Apps whose install steps succeeded; their result is verified independently below.
    $installedApps = New-Object System.Collections.Generic.List[object]
    $total = $sortedFw.Count + $apps.Count
    $done = 0
    $storeOk = $false
    Write-Section 'Installing frameworks'
    if ($sortedFw.Count -eq 0) { Write-StatusLine '' 'No additional frameworks are needed.' }
    foreach ($fw in $sortedFw) {
        Write-Log ('Framework (rank {0}): {1}' -f $fw.Rank, $fw.File.Name) -Quiet
        $script:InstallPosition = "$($done + 1) of $total"
        $null = Install-OnePackage -Package $fw -IsFramework
        $done++
    }

    Write-Section 'Installing apps'
    foreach ($app in $apps) {
        $title = if ($script:AppTitles.ContainsKey($app.Identity.Name)) { $script:AppTitles[$app.Identity.Name] } else { $app.Identity.Name }
        Write-Log "Installing $title`: $($app.File.Name)" -Quiet
        $script:InstallPosition = "$($done + 1) of $total"
        $appOk = Install-OnePackage -Package $app
        if ($appOk) { $installedApps.Add($app) }
        if ($app -eq $store) { $storeOk = $appOk }
        $done++
    }
    $script:InstallPosition = ''
    Clear-LiveLine

    Write-Section 'Verifying'
    try {
        if (-not (Test-InstallResult -Applications $installedApps.ToArray() -Frameworks $sortedFw)) { $storeOk = $false }
    }
    catch {
        Write-Log "Verification FAILED: $(Format-ErrorText $_.Exception.Message)" 'ERROR'
        Add-Failure 'Installation could not be verified'
    }

    Write-Log '---- Summary ----' -Quiet
    Write-Log "Store success : $storeOk" -Quiet
    Write-Log "Failure count : $script:FailCount" -Quiet
    foreach ($failure in $script:Failures) { Write-Log "  - $failure" -Quiet }
    Write-Log 'If the Store does not open, see Event Viewer > Applications and Services Logs > Microsoft > Windows > AppXDeployment-Server.' -Quiet

    # Open the Store from the Start menu. A restart helps if it does not start on a freshly installed system.
    $hint = if ($script:Counts.Installed -gt 0) { 'Open Microsoft Store from the Start menu. If it does not start, restart Windows and try again.' } else { $null }
    if (-not $storeOk) { return (Complete-Run 6 'Microsoft Store could not be installed' 'See the log and Event Viewer > Microsoft > Windows > AppXDeployment-Server.') }
    if ($script:FailCount -gt 0) { return (Complete-Run 5 'Microsoft Store is installed, with problems' $hint) }
    return (Complete-Run 0 'Microsoft Store is installed' $hint)
}
catch {
    Clear-LiveLine
    Write-Log "FATAL: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" 'ERROR'
    return (Complete-Run 7)
}
finally {
    # Ctrl+C and early exits skip Complete-Run: still restore the console and remove this run's downloads.
    if (-not $script:Completed) { Reset-RunState }
}
}   # end of Store-LTSC module

# Only the last value is the exit code (guards against stray pipeline output).
$StoreLtscExitCode = @($StoreLtscExitCode) | Select-Object -Last 1
$StoreLtscExitCode = if ($StoreLtscExitCode -is [int]) { $StoreLtscExitCode } else { 7 }
if ($PauseAtEnd) {
    $null = Read-Host '  Press Enter to close this window'
}
if ($OriginalScriptPath) { exit $StoreLtscExitCode }

# irm | iex: report the result without closing the caller's PowerShell window.
$global:LASTEXITCODE = $StoreLtscExitCode
}

# An outer param block would bind variables in the caller's scope under Invoke-Expression.
# Convert supported named arguments to a splat inside this private child scope instead.
$forward = @{}
$stringParameters = @('WorkDir', 'LogDir', 'Source', 'DownloadDir', 'DownloadTimeoutSeconds', 'TargetBuild', 'TargetArch', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
$switchParameters = @('DownloadOnly', 'KeepDownloads', 'NoProvision', 'SkipWinget', 'FixServices', 'CollectLogs', 'PauseAtEnd', 'Verbose', 'Debug')
try {
if (@($InvocationArguments | Where-Object { @('-?', '/?', '-h', '-help', '--help') -contains [string]$_ }).Count -gt 0) {
    foreach ($helpLine in @(
            '',
            "  Microsoft Store installer for Windows LTSC $StoreLtscVersion",
            '',
            '  Install:    irm https://raw.githubusercontent.com/Softhe/Store-LTSC/main/install.ps1 | iex',
            '  Options:    & ([scriptblock]::Create((irm <same url>))) -SkipWinget',
            '',
            '    -SkipWinget                   Skip App Installer and winget.',
            '    -NoProvision                  Install for the current user only.',
            '    -FixServices                  Set disabled services the Store needs back to Manual.',
            '    -CollectLogs                  Install nothing; save a diagnostics zip for a bug report.',
            '    -DownloadOnly                 Download the packages without installing them.',
            '    -TargetBuild <n>              With -DownloadOnly: packages for this Windows build (e.g. 19044).',
            '    -TargetArch x64|arm64|x86     With -DownloadOnly: packages for this architecture.',
            '    -DownloadDir <folder>         Save downloads here and keep them.',
            '    -KeepDownloads                Keep the temporary download folder.',
            '    -Source Online|Local|Auto     Download from Microsoft, use -WorkDir, or decide automatically.',
            '    -WorkDir <folder>             Folder with local packages and license files.',
            '    -LogDir <folder>              Write the log here.',
            '    -DownloadTimeoutSeconds <n>   Time limit for one package download (default 1800).',
            '',
            '  Exit codes: 0 success, 1 not elevated, 2 unsupported Windows build, 3 language mode, 4 package missing',
            '              or invalid, 5 partial failure, 6 Store not installed, 7 fatal or invalid option, 8 download failed,',
            '              9 a service that app installation needs is disabled.',
            ''
        )) { Write-Host $helpLine }
    if ($OriginalScriptPath) { exit 0 }
    $global:LASTEXITCODE = 0
    return
}
for ($index = 0; $index -lt $InvocationArguments.Count; $index++) {
    $argument = [string]$InvocationArguments[$index]
    if ($argument -notmatch '^-(?<Name>[a-zA-Z]+)(?::(?<Value>.*))?$') { throw "Expected a named parameter, received '$argument'." }
    $name = $Matches.Name
    $inlineValue = [string]$Matches.Value   # $null when the option has no ":value"
    if ($stringParameters -contains $name) {
        if ($argument.Contains(':') -and $inlineValue -ne '') { $forward[$name] = $inlineValue }
        else {
            if (++$index -ge $InvocationArguments.Count) { throw "Missing value for -$name." }
            $forward[$name] = $InvocationArguments[$index]
        }
    }
    elseif ($switchParameters -contains $name) {
        if ($inlineValue -eq '' -and ($index + 1) -lt $InvocationArguments.Count -and $InvocationArguments[$index + 1] -is [bool]) {
            # "-Switch:$false" in a script block call, or through pwsh -File, arrives as "-Switch[:]" and a boolean.
            $forward[$name] = $InvocationArguments[++$index]
        }
        elseif ($inlineValue -eq '' -and ($index + 1) -lt $InvocationArguments.Count -and [string]$InvocationArguments[$index + 1] -match '^\$(true|false)$') {
            # powershell.exe -File passes "-Switch:$false" as "-Switch" and the text "$false". Only named options
            # are accepted, so a "$true"/"$false" right after a switch can only be its value.
            $index++
            $forward[$name] = $Matches[1] -eq 'true'
        }
        elseif (-not $argument.Contains(':')) { $forward[$name] = $true }
        elseif ($inlineValue -match '^\$?(true|false)$') { $forward[$name] = $Matches[1] -eq 'true' }
        else { throw "Invalid switch value for -$name." }
    }
    else { throw "Unknown parameter -$name. Run with -Help to list the options." }
}
}
catch {
    # An option that cannot be understood is an invalid configuration (exit code 7), not a missing-elevation error.
    Write-Host ''
    Write-Host ('    FAIL  ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    if ($OriginalScriptPath) { exit 7 }
    $global:LASTEXITCODE = 7
    return
}
Invoke-StoreLtsc @forward
} $args $PSCommandPath
