#Requires -Version 5.1
# Reproduces the 2026-10-29 LTSC 2024 VM run: the Store service offered Microsoft.UI.Xaml.2.8 8.2501.31001.0 while
# 8.2511.26001.0 was already installed, so provisioning failed with "Element not found" and the run exited 5.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$names = @('Install-OnePackage', 'Find-InstalledFramework', 'Get-ProvisionedIdentity', 'Get-PackageIdentity', 'Get-PublisherId', 'Add-Failure', 'Format-ErrorText', 'Find-License', 'Test-InstallResult', 'Format-PackageLabel', 'Format-Brief')
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}
function Assert { param($Condition, $Message) if (-not $Condition) { throw $Message } }

$publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$script:Log = New-Object System.Collections.Generic.List[string]
function Write-Log { param($Message, $Level = 'INFO', [switch]$Quiet, $Console) $script:Log.Add("[$Level] $Message") }
function Write-Item { param($Status, $Text, $Note) $script:Log.Add("ITEM $Status $Text ($Note)") }
$script:AppTitles = @{}
function Get-AppxProvisionedPackage { param([switch]$Online, $ErrorAction) foreach ($n in $script:ProvisionedNames) { [pscustomobject]@{ PackageName = $n } } }
function Get-AppxPackage {
    param($Name, [switch]$AllUsers, $ErrorAction)
    $source = if ($AllUsers) { $script:AllUsersPackages } else { $script:UserPackages }
    @($source | Where-Object Name -eq $Name)
}
function Add-AppxProvisionedPackage { param([switch]$Online, $PackagePath, $LicensePath, $Regions, [switch]$SkipLicense) $script:ProvisionCalls++; if ($script:ProvisionError) { throw $script:ProvisionError } }
function Add-AppxPackage { param($Path, [switch]$ForceApplicationShutdown, [switch]$ForceUpdateFromAnyVersion) $script:InstallCalls++ }

function New-Installed($Version, $Arch = 'X64', $Status = 'Ok') { [pscustomobject]@{ Name = 'Microsoft.UI.Xaml.2.8'; Version = $Version; Architecture = $Arch; Publisher = $publisher; Status = $Status } }
$xaml = [pscustomobject]@{
    File     = [pscustomobject]@{ FullName = 'C:\pkgs\Microsoft.UI.Xaml.2.8_8.2501.31001.0_x64__8wekyb3d8bbwe.appx'; Name = 'Microsoft.UI.Xaml.2.8_8.2501.31001.0_x64__8wekyb3d8bbwe.appx' }
    Identity = [pscustomobject]@{ Name = 'Microsoft.UI.Xaml.2.8'; Version = [version]'8.2501.31001.0'; Arch = 'x64'; Family = 'Microsoft.UI.Xaml.2.8_8wekyb3d8bbwe'; Publisher = $publisher }
}
$store = [pscustomobject]@{
    File     = [pscustomobject]@{ FullName = 'C:\pkgs\store.msixbundle'; Name = 'store.msixbundle' }
    Identity = [pscustomobject]@{ Name = 'Microsoft.WindowsStore'; Version = [version]'22609.1401.8.0'; Arch = 'x64'; Family = 'Microsoft.WindowsStore_8wekyb3d8bbwe'; Publisher = $publisher
        Dependencies = @([pscustomobject]@{ Name = 'Microsoft.UI.Xaml.2.8'; Publisher = $publisher; MinVersion = [version]'8.2310.30001.0'; Arch = 'x64' }) }
}
$deploymentError = "Element not found.`r`n"

function Reset-State {
    param($Provisioned = @(), $User = @(), $AllUsers = @(), $ProvisionError = $null)
    $script:ProvisionedNames = $Provisioned; $script:UserPackages = $User; $script:AllUsersPackages = $AllUsers
    $script:ProvisionError = $ProvisionError; $script:ProvisionCalls = 0; $script:InstallCalls = 0
    $script:FailCount = 0; $script:Failures = New-Object System.Collections.Generic.List[string]
    $script:SupersededFrameworks = New-Object System.Collections.Generic.List[string]
    $script:ProvisionedCache = $null; $script:Log.Clear()
    $script:DoProvision = $true; $script:IsSystem = $false; $script:IsOnline = $true; $script:LicenseDirs = @()
}

# 1. Newer framework already provisioned: no older provisioning attempt, no failure.
Reset-State -Provisioned @('Microsoft.UI.Xaml.2.8_8.2511.26001.0_x64__8wekyb3d8bbwe') -User @(New-Installed '8.2511.26001.0') -AllUsers @(New-Installed '8.2511.26001.0')
$ok = Install-OnePackage -Package $xaml -IsFramework
Assert ($ok -and $script:FailCount -eq 0) 'A newer provisioned framework must not count as a failure.'
Assert ($script:ProvisionCalls -eq 0 -and $script:InstallCalls -eq 0) 'Older framework copies must not be deployed over newer ones.'

# 2. The VM case: newer installed but provisioning still rejects the older copy. Deferred to verification.
Reset-State -User @(New-Installed '8.2511.26001.0') -AllUsers @(New-Installed '8.2511.26001.0') -ProvisionError $deploymentError
$ok = Install-OnePackage -Package $xaml -IsFramework
Assert ($ok -and $script:FailCount -eq 0 -and $script:SupersededFrameworks.Count -eq 1) 'A provisioning rejection caused by a newer framework must be deferred, not counted.'
Assert ($script:InstallCalls -eq 0) 'Current-user registration must be skipped when a newer framework is registered.'
Assert (-not ($script:Log | Where-Object { $_ -match '\r|\n' })) 'Multi-line deployment errors must be logged on one line.'
Assert (@($script:Log | Where-Object { $_ -like 'ITEM *' }).Count -eq 1 -and ($script:Log -match '^ITEM SKIP .*version 8\.2511\.26001\.0 already installed')) 'The console must show one SKIP line naming the newer version.'

# 2a. Verification counts the failure when new users would lack the dependency.
$script:ProvisionedNames = @('Microsoft.WindowsStore_22609.1401.8.0_neutral_~_8wekyb3d8bbwe'); $script:UserPackages += [pscustomobject]@{ Name = 'Microsoft.WindowsStore'; Version = '22609.1401.8.0'; Status = 'Ok' }
$storeRegistered = Test-InstallResult -Applications @($store)
Assert ($storeRegistered -and $script:FailCount -eq 1) 'A dependency missing for new users must be a partial failure.'

# 2b. Verification passes when a newer provisioned framework satisfies the dependency.
$script:FailCount = 0; $script:Failures.Clear()
$script:ProvisionedNames += 'Microsoft.UI.Xaml.2.8_8.2511.26001.0_x64__8wekyb3d8bbwe'
$storeRegistered = Test-InstallResult -Applications @($store)
Assert ($storeRegistered -and $script:FailCount -eq 0) 'A newer provisioned framework satisfies the Store dependency.'

# 2c. A framework's own dependency is checked too (app -> UI.Xaml -> nested framework).
$script:FailCount = 0; $script:Failures.Clear()
$nestedDep = [pscustomobject]@{ Name = 'Microsoft.Nested.Framework'; Publisher = $publisher; MinVersion = [version]'1.0.0.0'; Arch = 'x64' }
$xamlWithDep = [pscustomobject]@{ File = $xaml.File; Identity = [pscustomobject]@{ Name = $xaml.Identity.Name; Version = $xaml.Identity.Version; Arch = 'x64'; Family = $xaml.Identity.Family; Publisher = $publisher; Dependencies = @($nestedDep) } }
$null = Test-InstallResult -Applications @($store) -Frameworks @($xamlWithDep)
Assert ($script:FailCount -eq 1) 'A nested framework missing for new users must be a partial failure.'

# 2d. An unprovisioned app is not reported as verified.
$script:FailCount = 0; $script:Failures.Clear(); $script:Log.Clear()
$script:ProvisionedNames = @('Microsoft.UI.Xaml.2.8_8.2511.26001.0_x64__8wekyb3d8bbwe')
$null = Test-InstallResult -Applications @($store)
Assert ($script:FailCount -eq 1 -and -not ($script:Log | Where-Object { $_ -match 'New users: .* provisioned' })) 'An unprovisioned app must not be reported as verified.'

# 3. A provisioning error without a newer framework remains a failure.
Reset-State -ProvisionError $deploymentError
$ok = Install-OnePackage -Package $xaml -IsFramework
Assert ((-not $ok) -and $script:FailCount -eq 1 -and $script:InstallCalls -eq 1) 'A genuine provisioning failure must be counted.'

# 4. An older installed version does not suppress deployment.
Reset-State -User @(New-Installed '8.2310.30001.0') -AllUsers @(New-Installed '8.2310.30001.0')
$ok = Install-OnePackage -Package $xaml -IsFramework
Assert ($ok -and $script:ProvisionCalls -eq 1 -and $script:InstallCalls -eq 1) 'An older framework must be upgraded.'

# 5. Other architectures do not count as the same framework.
Reset-State -User @(New-Installed '8.2511.26001.0' 'X86') -AllUsers @(New-Installed '8.2511.26001.0' 'X86') -ProvisionError $deploymentError
$null = Install-OnePackage -Package $xaml -IsFramework
Assert ($script:FailCount -eq 1) 'An x86 framework must not excuse an x64 provisioning failure.'

# 6. A current-user copy that needs repair is re-registered, not skipped.
Reset-State -Provisioned @('Microsoft.UI.Xaml.2.8_8.2511.26001.0_x64__8wekyb3d8bbwe') -User @(New-Installed '8.2511.26001.0' 'X64' 'NeedsRemediation') -AllUsers @(New-Installed '8.2511.26001.0')
$null = Install-OnePackage -Package $xaml -IsFramework
Assert ($script:InstallCalls -eq 1) 'An unhealthy registered framework must not suppress registration.'

Write-Host 'PASS: superseded frameworks are skipped or deferred to verification, real failures are counted, and errors log on one line.'
