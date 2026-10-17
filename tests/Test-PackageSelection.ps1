$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$source = Join-Path $PSScriptRoot '..\install.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @('Get-PackageIdentity', 'Get-PublisherId', 'Read-PackageManifest', 'Get-PackageMetadata', 'Get-ArchRank', 'Get-PackageDependencyState', 'Format-MissingDependency', 'Get-DependencyInstallOrder', 'Select-NewerPackage')
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $names) { Invoke-Expression $node.Extent.Text }
}
function Write-Log { param($Message, $Level) }
function Get-AppxPackage { param($Name, $ErrorAction) return @() }
function Get-AppxProvisionedPackage { param([switch]$Online, $ErrorAction) return $script:ProvisionedFixtures }
function Assert { param($Condition, $Message) if (-not $Condition) { throw $Message } }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$temp = Join-Path ([IO.Path]::GetTempPath()) ('store-selection-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
function New-Fixture {
    param($Name, $Arch, $Version = '1.0.0.0', $Dependencies = '', [switch]$Framework)
    $path = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.appx')
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('AppxManifest.xml')
        $writer = New-Object IO.StreamWriter($entry.Open())
        try { $writer.Write('<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="' + $Name + '" Version="' + $Version + '" Publisher="CN=Test" ProcessorArchitecture="' + $Arch + '"/><Properties><Framework>' + $Framework.IsPresent.ToString().ToLowerInvariant() + '</Framework></Properties><Dependencies>' + $Dependencies + '</Dependencies></Package>') } finally { $writer.Dispose() }
    } finally { $archive.Dispose() }
    return [pscustomobject]@{ File = Get-Item $path; Identity = Get-PackageMetadata $path 'x64' 26100; Rank = Get-ArchRank $Arch 'x64' 26100 }
}
try {
    $script:ProvisionedFixtures = @()
    $script:DoProvision = $false
    Assert ((Get-PublisherId 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') -eq '8wekyb3d8bbwe') 'Publisher ID must match the known Microsoft publisher.'
    $native = New-Fixture 'Microsoft.WindowsStore' 'x64'
    $foreign = New-Fixture 'Microsoft.WindowsStore' 'arm64' '2.0.0.0'
    Assert ($native.Identity.Name -eq 'Microsoft.WindowsStore') 'Renamed package must use manifest identity.'
    $selected = $null
    foreach ($pkg in @($native, $foreign)) { if ($pkg.Rank -gt 0) { $selected = Select-NewerPackage $selected $pkg } }
    Assert ($selected.Identity.Arch -eq 'x64') 'Incompatible newer app must not win.'
    $emulated = New-Fixture 'Microsoft.WindowsStore' 'x86'
    Assert ((Select-NewerPackage $emulated $native).Identity.Arch -eq 'x64') 'Equal-version app must prefer native architecture.'
    $base = New-Fixture 'Test.Base' 'x64' -Framework
    $dep = '<PackageDependency Name="Test.Base" Publisher="CN=Test" MinVersion="1.0.0.0"/>'
    $top = New-Fixture 'Test.Top' 'x64' -Framework -Dependencies $dep
    $app = New-Fixture 'Test.App' 'x64' -Dependencies '<PackageDependency Name="Test.Top" Publisher="CN=Test" MinVersion="1.0.0.0"/>'
    $order = @(Get-DependencyInstallOrder @($top, $base) @($app))
    Assert ($order[0].Identity.Name -eq 'Test.Base' -and $order[1].Identity.Name -eq 'Test.Top') 'Frameworks must install in dependency order.'
    $failed = $false
    try { $null = Get-DependencyInstallOrder @($top) @($app) } catch { $failed = $_.Exception.Message -like '*Missing dependency*Test.Base*' }
    Assert $failed 'Missing dependency must fail before installation.'
    $base.Identity.Dependencies = @([pscustomobject]@{ Name='Test.Top'; Publisher='CN=Test'; MinVersion=[version]'1.0.0.0'; Arch='x64' })
    $failed = $false
    try { $null = Get-DependencyInstallOrder @($top, $base) @() } catch { $failed = $_.Exception.Message -like '*cycle*' }
    Assert $failed 'Framework dependency cycle must fail.'
    $newOS = New-Fixture 'Test.NewOS' 'x64' -Dependencies '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.99999.0"/>'
    Assert (-not $newOS.Identity.Supported) 'Unsupported minimum OS version must remain a filterable candidate.'
    Assert $native.Identity.Supported 'Compatible candidate in a mixed folder must remain usable.'
    $revisionPackage = New-Fixture 'Test.Revision' 'x64' -Dependencies '<TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.26100.1000"/>'
    Assert (-not $revisionPackage.Identity.Supported) 'A package requiring a later update revision must remain unsupported.'
    $revisionMetadata = Get-PackageMetadata $revisionPackage.File.FullName 'x64' 26100 -Revision 1000
    Assert $revisionMetadata.Supported 'Installed update revision must satisfy the exact minimum version.'
    $olderRevisionMetadata = Get-PackageMetadata $revisionPackage.File.FullName 'x64' 26100 -Revision 999
    Assert (-not $olderRevisionMetadata.Supported) 'An older update revision must not satisfy the minimum version.'
    $script:DoProvision = $true
    $publisherId = Get-PublisherId 'CN=Test'
    $script:ProvisionedFixtures = @([pscustomobject]@{ PackageName = "Test.Top_1.0.0.0_x64__$publisherId" })
    $provisionedOrder = @(Get-DependencyInstallOrder @() @($app))
    Assert ($provisionedOrder.Count -eq 0) 'Provisioned framework must satisfy dependencies without per-user registration.'
    $script:DoProvision = $false
    # A bundle with an incompatible payload listed first must choose its native payload.
    $bundlePath = Join-Path $temp 'renamed.msixbundle'
    $archive = [IO.Compression.ZipFile]::Open($bundlePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('AppxMetadata/AppxBundleManifest.xml')
        $writer = New-Object IO.StreamWriter($entry.Open())
        try { $writer.Write('<Bundle><Identity Name="Microsoft.WindowsStore" Version="1.0.0.0" Publisher="CN=Test"/><Packages><Package Type="application" Architecture="arm64" FileName="arm.appx"/><Package Type="application" Architecture="x64" FileName="native.appx"/></Packages></Bundle>') } finally { $writer.Dispose() }
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $native.File.FullName, 'native.appx')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $foreign.File.FullName, 'arm.appx')
    } finally { $archive.Dispose() }
    $bundle = Get-PackageMetadata $bundlePath 'x64' 26100
    Assert ($bundle.Arch -eq 'x64' -and $bundle.Name -eq 'Microsoft.WindowsStore') 'Bundle must select compatible native payload.'
    Write-Output 'Package selection tests passed.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
