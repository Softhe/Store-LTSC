#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Format-AppTitle', 'Test-OfflineManifest', 'Save-OnlinePackages', 'Test-PackageFile', 'Save-PackageDownload', 'Save-OnlinePackage', 'Add-Failure', 'Get-PublisherId')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Write-Log { param($Message, $Level) }
function Write-Item { param($Status, $Text, $Note) }
function Show-Activity { param($Text, $Fraction, $Detail) }
function Clear-LiveLine { }
function Format-Clock { param($Time) '0:00' }
function Format-PackageLabel { param($Identity) $Identity.Name }
function Get-AuthenticodeSignature { param($LiteralPath) [pscustomobject]@{Status='Valid'; SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation'}} }
function Assert-Throws { param([scriptblock]$Action, [string]$Pattern) try { & $Action; throw 'Expected rejection was absent' } catch { if ($_.Exception.Message -notmatch $Pattern) { throw } } }
$folder = Join-Path ([IO.Path]::GetTempPath()) ('StoreLtsc-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $folder
try {
    $package = Join-Path $folder 'sample.appx'
    Set-Content -LiteralPath $package -Value 'test bytes'
    $manifest = @{SchemaVersion=1; OsArch='x64'; Build=19041; RequestedFamilies=@('Store'); MissingFamilies=@(); Files=@(@{Name='sample.appx'; Size=(Get-Item $package).Length; Sha256=(Get-FileHash $package).Hash})}
    $manifestPath = Join-Path $folder 'store-packages.json'
    function Save-Manifest { $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 }
    Save-Manifest
    $result = @(Test-OfflineManifest -Directory $folder -OsArch x64 -Build 19041 -Families Store)
    if ($result.Count -ne 1) { throw 'Expected one verified file' }
    Assert-Throws { Test-OfflineManifest -Directory $folder -OsArch arm64 -Build 19041 -Families Store } 'target'
    Assert-Throws { Test-OfflineManifest -Directory $folder -OsArch x64 -Build 19041 -Families Winget } 'does not include'
    $manifest.MissingFamilies = @('Winget'); Save-Manifest
    $null = Test-OfflineManifest -Directory $folder -OsArch x64 -Build 19041 -Families Store
    $manifest.MissingFamilies = @('Store'); Save-Manifest
    Assert-Throws { Test-OfflineManifest -Directory $folder -OsArch x64 -Build 19041 -Families Store } 'missing requested'
    $manifest.MissingFamilies = @(); $manifest.Files[0].Name = '..\sample.appx'; Save-Manifest
    Assert-Throws { Test-OfflineManifest -Directory $folder -OsArch x64 -Build 19041 -Families Store } 'Invalid'
    $manifest.Files[0].Name = 'sample.appx'; Save-Manifest
    Add-Content -LiteralPath $package -Value 'changed'
    Assert-Throws { Test-OfflineManifest -Directory $folder -OsArch x64 -Build 19041 -Families Store } 'mismatch'
    Write-Host 'PASS: offline manifest verifies files and rejects incompatible, missing, unsafe, or corrupt inputs.'
    # A loopback server accepts the request but never sends a response.
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $port = $listener.LocalEndpoint.Port
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { Save-PackageDownload -Url "http://127.0.0.1:$port/stall" -Path (Join-Path $folder 'stall.part') -TimeoutSeconds 1 } 'time limit'
        if ($watch.Elapsed.TotalSeconds -gt 10) { throw 'Download cancellation took too long' }
    } finally { $listener.Stop() }
    Write-Host 'PASS: stalled download cancels within its deadline.'
    # A loopback server that honours Range requests: a full download reports progress, and a partial file is resumed.
    $payload = New-Object byte[] 700000; (New-Object Random 7).NextBytes($payload)
    $requests = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    $server = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $server.Start()
    $serverShell = [powershell]::Create().AddScript({
        param($listener, $bytes, $requests)
        while ($true) {
            try { $client = $listener.AcceptTcpClient() } catch { break }
            try {
                $stream = $client.GetStream()
                $reader = New-Object IO.StreamReader($stream)
                $start = 0
                while (($line = $reader.ReadLine())) { if ($line -match '^Range: bytes=(\d+)-') { $start = [int]$Matches[1] } }
                $null = $requests.Add($start)
                $head = if ($start -gt 0) { "HTTP/1.1 206 Partial Content`r`nContent-Range: bytes $start-$($bytes.Length - 1)/$($bytes.Length)`r`n" } else { "HTTP/1.1 200 OK`r`n" }
                $head = [Text.Encoding]::ASCII.GetBytes($head + "Content-Length: $($bytes.Length - $start)`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length); $stream.Write($bytes, $start, $bytes.Length - $start); $stream.Flush()
            } catch { } finally { $client.Close() }
        }
    }).AddArgument($server).AddArgument($payload).AddArgument($requests)
    $serverRun = $serverShell.BeginInvoke()
    try {
        $url = "http://127.0.0.1:$($server.LocalEndpoint.Port)/package"
        $full = Join-Path $folder 'full.part'
        $script:Reports = New-Object System.Collections.Generic.List[object]
        Save-PackageDownload -Url $url -Path $full -TimeoutSeconds 30 -OnProgress { param($received, $total) $script:Reports.Add(@($received, $total)) }
        if ((Get-FileHash $full).Hash -ne (Get-FileHash -InputStream ([IO.MemoryStream]::new($payload))).Hash) { throw 'Downloaded file differs from the served content' }
        if ($script:Reports.Count -eq 0 -or $script:Reports[-1][0] -ne $payload.Length -or $script:Reports[-1][1] -ne $payload.Length) { throw 'Download progress must end at the full size' }
        $partial = Join-Path $folder 'resume.part'
        [IO.File]::WriteAllBytes($partial, [byte[]]$payload[0..299999])
        Save-PackageDownload -Url $url -Path $partial -TimeoutSeconds 30
        if ($requests[-1] -ne 300000) { throw "A partial file must be resumed from its length, requested from $($requests[-1])" }
        if ((Get-FileHash $partial).Hash -ne (Get-FileHash $full).Hash) { throw 'Resumed file differs from the served content' }
    } finally { $server.Stop(); $serverShell.Dispose() }
    Write-Host 'PASS: download reports progress and resumes a partial file.'
    function Initialize-Network { }
    function Test-Clock { }
    function Get-Fe3DeviceAttributes { param($OsArch, $Build) 'test' }
    function Get-Fe3Cookie { 'test' }
    function Get-WuCategoryId { param($PackageFamilyName) if ($PackageFamilyName -eq 'Winget') { throw 'mock lookup failure' }; 'store-category' }
    function Get-ArchRank { param($Arch, $OsArch, $Build) 1 }
    function Get-Fe3PackageList {
        param($CategoryId, $Cookie, $DeviceAttributes)
        [pscustomobject]@{Moniker='sample'; Extension='.appx'; Size=(Get-Item $package).Length; IsFramework=$false; PackageRank=1; Identity=[pscustomobject]@{Name='Store'; Family='Store'; Arch='x64'; Version=[version]'1.0'}; Sha256=[Convert]::ToBase64String([byte[]](1..32)); Sha1='unused'}
    }
    function Test-PackageFile { param($Path, $Package) return $null }
    $script:StoreFamily = 'Store'; $script:FailCount = 0; $script:Failures = New-Object System.Collections.Generic.List[string]
    $script:OnlineFrameworkNames = New-Object 'System.Collections.Generic.HashSet[string]'
    $DownloadTimeoutSeconds = 2
    function Get-PackageMetadata { param($Path, $OsArch, $Build, $Revision) [pscustomobject]@{ Dependencies = @(); Supported = $true; Arch = 'x64' } }
    $result = @(Save-OnlinePackages -Destination $folder -Families @('Store', 'Winget') -OsArch x64 -Build 19041)
    if ($script:FailCount -ne 1 -or $result.Count -ne 1) { throw 'Missing requested app did not record partial failure' }
    $saved = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (@($saved.MissingFamilies) -notcontains 'Winget' -or @($saved.Files).Count -ne 1) { throw 'Incomplete download was not recorded in manifest' }
    Write-Host 'PASS: missing requested companion records partial failure and incomplete manifest.'
    # Frameworks are downloaded only when an app, or a framework it needs, declares them.
    foreach ($n in 'used', 'nested', 'unused') { Set-Content -LiteralPath (Join-Path $folder "$n.appx") -Value $n }
    function New-Offer($Moniker, $Name, [switch]$Framework) { [pscustomobject]@{Moniker=$Moniker; Extension='.appx'; Size=1; IsFramework=[bool]$Framework; PackageRank=1; Identity=[pscustomobject]@{Name=$Name; Family=$Name; Arch='x64'; Version=[version]'2.0'}; Sha256=$null; Sha1='unused'} }
    function Get-Fe3PackageList { param($CategoryId, $Cookie, $DeviceAttributes) (New-Offer sample Store); (New-Offer used Fw.Used -Framework); (New-Offer nested Fw.Nested -Framework); (New-Offer unused Fw.Unused -Framework) }
    function Get-PackageMetadata {
        param($Path, $OsArch, $Build, $Revision)
        $declared = @{ 'sample.appx' = 'Fw.Used'; 'used.appx' = 'Fw.Nested' }[[IO.Path]::GetFileName($Path)]
        [pscustomobject]@{ Supported = ($script:Unsupported -notcontains [IO.Path]::GetFileName($Path)); Arch = 'x64'; Dependencies = @(if ($declared) { [pscustomobject]@{ Name = $declared; Publisher = $null; MinVersion = [version]'1.0'; Arch = 'x64' } }) }
    }
    $script:Unsupported = @()
    $script:FailCount = 0; $script:Failures.Clear()
    $result = @(Save-OnlinePackages -Destination $folder -Families @('Store') -OsArch x64 -Build 19041)
    $names = @($result | ForEach-Object Name | Sort-Object)
    if (($names -join ',') -ne 'nested.appx,sample.appx,used.appx') { throw "Expected only declared frameworks, got $($names -join ',')" }
    $saved = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (@($saved.Files).Count -ne 3) { throw 'Manifest must list only downloaded files' }
    Write-Host 'PASS: only declared frameworks (including nested dependencies) are downloaded.'
    # A framework an app declares but the service does not offer: an install may still find it on the PC, but a
    # download-only folder would be incomplete, so -RequireComplete makes it a failure and the manifest records it.
    function Get-Fe3PackageList { param($CategoryId, $Cookie, $DeviceAttributes) (New-Offer sample Store); (New-Offer used Fw.Used -Framework) }
    $script:FailCount = 0; $script:Failures.Clear()
    $null = @(Save-OnlinePackages -Destination $folder -Families @('Store') -OsArch x64 -Build 19041)
    $saved = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($script:FailCount -ne 0 -or @($saved.MissingDependencies) -notcontains 'Fw.Nested 1.0 or newer (x64)') { throw "An install run must record, not fail, a framework the service does not offer (failures $script:FailCount, manifest '$(@($saved.MissingDependencies) -join ', ')')" }
    $null = @(Save-OnlinePackages -Destination $folder -Families @('Store') -OsArch x64 -Build 19041 -RequireComplete)
    if ($script:FailCount -ne 1 -or $script:Failures[0] -notmatch 'Framework not offered: Fw\.Nested') { throw 'A download-only run must fail when a declared framework is not offered.' }
    Write-Host 'PASS: a declared framework the service does not offer fails a download-only run and is recorded in the manifest.'
    # The service offers the same packages to every Windows build. A best version that needs a newer Windows
    # is replaced by the next version on offer; with no usable Store version the download fails.
    foreach ($n in 'new', 'old') { Set-Content -LiteralPath (Join-Path $folder "$n.appx") -Value $n }
    function Get-Fe3PackageList {
        param($CategoryId, $Cookie, $DeviceAttributes)
        $newer = New-Offer new Store; $newer.PackageRank = 2; $newer.Identity.Version = [version]'3.0'
        $newer; (New-Offer old Store)
    }
    $script:Unsupported = @('new.appx'); $script:FailCount = 0; $script:Failures.Clear()
    $result = @(Save-OnlinePackages -Destination $folder -Families @('Store') -OsArch x64 -Build 19044)
    if (($result | ForEach-Object Name) -join ',' -ne 'old.appx' -or $script:FailCount -ne 0) { throw "Expected the older supported Store version, got $(($result | ForEach-Object Name) -join ',')" }
    if (Test-Path -LiteralPath (Join-Path $folder 'new.appx')) { throw 'An unsupported download must not stay in the package folder' }
    Set-Content -LiteralPath (Join-Path $folder 'new.appx') -Value 'new'
    $script:Unsupported = @('new.appx', 'old.appx')
    Assert-Throws { Save-OnlinePackages -Destination $folder -Families @('Store') -OsArch x64 -Build 17763 } 'no Microsoft Store version'
    Write-Host 'PASS: an app version this Windows build cannot run falls back to an older offered version.'} finally { Remove-Item -LiteralPath $folder -Recurse -Force }
