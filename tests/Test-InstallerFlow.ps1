#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
# Deployment orchestration runs in Windows PowerShell in production, including PS7 entry points.
if ($PSVersionTable.PSEdition -eq 'Core') {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File $PSCommandPath
    exit $LASTEXITCODE
}
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\install.ps1') -Raw
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$command = $ast.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Module' }, $true)
$body = @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] })[0].ScriptBlock
$mainTry = @($body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$mocks = @'
function Test-IsElevated { $true }
function Test-IsSystemAccount { $false }
function Get-OsArch { 'x64' }
function Get-ItemProperty { param($Path) [pscustomobject]@{ CurrentBuildNumber = '26100'; UBR = 0 } }
function Unblock-File { [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process {} }
function Install-OnePackage {
    param($Package, [switch]$IsFramework)
    $global:ReviewInstallCalls++
    if ($global:ReviewUnregistered -notcontains $Package.Identity.Name) { $global:ReviewRegistered += $Package.Identity.Name }
    $true
}
function Get-AppxPackage { param($Name, [switch]$AllUsers, $ErrorAction) if ($global:ReviewRegistered -contains $Name) { [pscustomobject]@{ Name = $Name; Version = '1.0.0.0'; Status = 'Ok' } } }
function Get-AppxProvisionedPackage { param([switch]$Online, $ErrorAction) }
'@
$bodyText = $body.Extent.Text
$offset = $mainTry.Extent.StartOffset - $body.Extent.StartOffset
$bodyText = $bodyText.Insert($offset, $mocks + "`n")
$bodyText = $bodyText.Substring(1, $bodyText.Length - 2)
$moduleScript = [scriptblock]::Create($bodyText)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('store-flow-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
function New-TestPackage($Name, $Arch = 'x64', $Version = '1.0.0.0', $Dependencies = '', $Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US', [switch]$Framework) {
    $path = Join-Path $testRoot ($Name + '_' + $Version + '_' + $Arch + '__8wekyb3d8bbwe.appx')
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $writer = New-Object IO.StreamWriter($archive.CreateEntry('AppxManifest.xml').Open())
        try { $writer.Write('<Package><Identity Name="' + $Name + '" Version="' + $Version + '" Publisher="' + $Publisher + '" ProcessorArchitecture="' + $Arch + '"/><Properties><Framework>' + $Framework.IsPresent.ToString().ToLowerInvariant() + '</Framework></Properties><Dependencies>' + $Dependencies + '</Dependencies></Package>') } finally { $writer.Dispose() }
    } finally { $archive.Dispose() }
    $path
}
function Invoke-Flow($WorkDir = $testRoot) {
    $global:ReviewInstallCalls = 0
    $global:ReviewRegistered = @()
    $invocation = @{ Params = @{ WorkDir=$WorkDir; LogDir=(Join-Path $testRoot 'Logs'); Source='Local'; DownloadDir=''; DownloadTimeoutSeconds=1; DownloadOnly=$false; KeepDownloads=$false; NoProvision=$true; SkipWinget=$false }; Bound=@{}; ScriptPath=$null; ScriptText='' }
    $result = @(New-Module -Name StoreFlowTest -ArgumentList $invocation -ReturnResult -ScriptBlock $moduleScript)
    return $result[-1]
}
$global:ReviewUnregistered = @()
try {
    $null = New-TestPackage Microsoft.WindowsStore
    $code = Invoke-Flow
    if ($code -ne 5 -or $global:ReviewInstallCalls -ne 1) { throw "Store-only local flow expected code5 and one install, got $code / $global:ReviewInstallCalls" }
    foreach ($name in 'Microsoft.StorePurchaseApp','Microsoft.XboxIdentityProvider','Microsoft.DesktopAppInstaller') { $null = New-TestPackage $name }
    $null = New-TestPackage Microsoft.WindowsStore arm64 9.0.0.0
    $code = Invoke-Flow
    if ($code -ne 0 -or $global:ReviewInstallCalls -ne 4) { throw "Complete mixed-architecture flow expected code0/four installs, got $code / $global:ReviewInstallCalls" }
    # Relative and implicit -Source Local folders resolve against the PowerShell location, not the process directory.
    Push-Location -LiteralPath (Split-Path -Parent $testRoot)
    try { $code = Invoke-Flow (Split-Path -Leaf $testRoot) } finally { Pop-Location }
    if ($code -ne 0 -or $global:ReviewInstallCalls -ne 4) { throw "Relative WorkDir expected code0/four installs, got $code / $global:ReviewInstallCalls" }
    Push-Location -LiteralPath $testRoot
    try { $code = Invoke-Flow '' } finally { Pop-Location }
    if ($code -ne 0 -or $global:ReviewInstallCalls -ne 4) { throw "Local source without WorkDir expected the current folder, got $code / $global:ReviewInstallCalls" }
    # A reported install that Windows does not show as registered is not a success.
    $global:ReviewUnregistered = @('Microsoft.WindowsStore')
    try { $code = Invoke-Flow } finally { $global:ReviewUnregistered = @() }
    if ($code -ne 6) { throw "Store missing after a reported install must be a Store failure, got $code" }
    $global:ReviewUnregistered = @('Microsoft.DesktopAppInstaller')
    try { $code = Invoke-Flow } finally { $global:ReviewUnregistered = @() }
    if ($code -ne 5) { throw "Companion missing after a reported install must be a partial failure, got $code" }
    $null = New-TestPackage Microsoft.XboxIdentityProvider x64 2.0.0.0 '<PackageDependency Name="Missing.Framework" Publisher="CN=Microsoft Corporation" MinVersion="1.0.0.0"/>'
    $code = Invoke-Flow
    if ($code -ne 5 -or $global:ReviewInstallCalls -ne 3) { throw "Optional app with a missing dependency must be skipped without blocking the Store, got $code / $global:ReviewInstallCalls" }
    $null = New-TestPackage Microsoft.WindowsStore x64 2.0.0.0 '<PackageDependency Name="Missing.Framework" Publisher="CN=Microsoft Corporation" MinVersion="1.0.0.0"/>'
    $code = Invoke-Flow
    if ($code -ne 4 -or $global:ReviewInstallCalls -ne 0) { throw "Missing dependency should reject before any install, got $code / $global:ReviewInstallCalls" }
    # Only frameworks an app declares are installed: four apps plus the one declared framework.
    $null = New-TestPackage Missing.Framework x64 1.0.0.0 '' 'CN=Microsoft Corporation' -Framework
    $null = New-TestPackage Unused.Framework x64 1.0.0.0 '' 'CN=Microsoft Corporation' -Framework
    $code = Invoke-Flow
    if ($code -ne 0 -or $global:ReviewInstallCalls -ne 5) { throw "Undeclared framework must be skipped, got $code / $global:ReviewInstallCalls" }
    Write-Host 'PASS: actual installer orchestration resolves relative folders, reports partial sets, selects usable apps, skips optional apps with missing dependencies, rejects missing Store dependencies before installation, and skips undeclared frameworks.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'store-flow-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
    Remove-Variable -Name ReviewInstallCalls, ReviewRegistered, ReviewUnregistered -Scope Global -ErrorAction SilentlyContinue
}
