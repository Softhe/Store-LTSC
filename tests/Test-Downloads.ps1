#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Test-OfflineManifest', 'Save-OnlinePackages', 'Test-PackageFile', 'Save-PackageDownload', 'Save-OnlinePackage', 'Add-Failure', 'Get-PublisherId')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Write-Log { param($Message, $Level) }
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
    function Initialize-Network { }
    function Get-Fe3DeviceAttributes { param($OsArch, $Build) 'test' }
    function Get-Fe3Cookie { 'test' }
    function Get-WuCategoryId { param($PackageFamilyName) if ($PackageFamilyName -eq 'Winget') { throw 'mock lookup failure' }; 'store-category' }
    function Get-ArchRank { param($Arch, $OsArch, $Build) 1 }
    function Get-Fe3PackageList {
        param($CategoryId, $Cookie, $DeviceAttributes)
        [pscustomobject]@{Moniker='sample'; Extension='.appx'; Size=(Get-Item $package).Length; IsFramework=$false; PackageRank=1; Identity=[pscustomobject]@{Name='Store'; Family='Store'; Arch='x64'; Version=[version]'1.0'}; Sha256=[Convert]::ToBase64String([byte[]](1..32)); Sha1='unused'}
    }
    function Test-PackageFile { param($Path, $Package, [switch]$SkipSignature) return $null }
    $script:StoreFamily = 'Store'; $script:FailCount = 0; $script:Failures = New-Object System.Collections.Generic.List[string]
    $script:OnlineFrameworkNames = New-Object 'System.Collections.Generic.HashSet[string]'
    $DownloadTimeoutSeconds = 2
    function Get-PackageMetadata { param($Path, $OsArch, $Build, $Revision) [pscustomobject]@{ Dependencies = @() } }
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
        [pscustomobject]@{ Dependencies = @(if ($declared) { [pscustomobject]@{ Name = $declared; Publisher = $null; MinVersion = [version]'1.0'; Arch = 'x64' } }) }
    }
    $script:FailCount = 0; $script:Failures.Clear()
    $result = @(Save-OnlinePackages -Destination $folder -Families @('Store') -OsArch x64 -Build 19041)
    $names = @($result | ForEach-Object Name | Sort-Object)
    if (($names -join ',') -ne 'nested.appx,sample.appx,used.appx') { throw "Expected only declared frameworks, got $($names -join ',')" }
    $saved = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (@($saved.Files).Count -ne 3) { throw 'Manifest must list only downloaded files' }
    Write-Host 'PASS: only declared frameworks (including nested dependencies) are downloaded.'
} finally { Remove-Item -LiteralPath $folder -Recurse -Force }
