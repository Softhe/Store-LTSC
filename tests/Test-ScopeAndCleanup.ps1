#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$installerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\install.ps1') -Raw
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($installerText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
function Assert-True($Value, $Message) { if (-not $Value) { throw $Message } }

# This combination exits before OS, elevation, logging, networking, or package operations.
& {
    $WorkDir = 'original work directory'; $Source = 'original source'; $kv = 'original loop value'
    $DownloadOnly = 'original switch'; $StoreLtscInvocation = 'original invocation'
    & ([scriptblock]::Create($installerText)) -DownloadOnly -Source Local -SkipWinget:$false -DownloadTimeoutSeconds 17
    Assert-True ($LASTEXITCODE -eq 7) 'Scriptblock options did not reach the preflight guard.'
    Assert-True ($WorkDir -eq 'original work directory' -and $Source -eq 'original source' -and $kv -eq 'original loop value') 'Caller variables changed.'
    Assert-True ($DownloadOnly -eq 'original switch' -and $StoreLtscInvocation -eq 'original invocation') 'Caller parameter or wrapper variables changed.'
    Assert-True (-not (Get-Command Invoke-StoreLtsc -ErrorAction SilentlyContinue)) 'Entry function leaked into caller scope.'
    $splat = @{ DownloadOnly = $true; Source = 'Local'; WorkDir = ''; SkipWinget = $false }
    & ([scriptblock]::Create($installerText)) @splat
    Assert-True ($LASTEXITCODE -eq 7) 'Hashtable forwarding lost an empty string or boolean argument.'
}

# Substitute only the module invocation with a harmless result to exercise the actual iex wrapper.
$moduleCommand = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-Module' }, $true) | Select-Object -First 1
$safeSource = $installerText.Remove($moduleCommand.Extent.StartOffset, $moduleCommand.Extent.EndOffset - $moduleCommand.Extent.StartOffset).Insert($moduleCommand.Extent.StartOffset, '5')
& {
    $WorkDir = 'retained'; $Source = 'retained'; $kv = 'retained'
    Invoke-Expression $safeSource
    Assert-True ($LASTEXITCODE -eq 5) 'Invoke-Expression did not publish the exit code.'
    Assert-True ($WorkDir -eq 'retained' -and $Source -eq 'retained' -and $kv -eq 'retained') 'Invoke-Expression changed caller variables.'
}

# Load the actual functions without running the installer.
foreach ($name in @('Complete-Run', 'Invoke-Relaunch', 'Clear-Progress')) {
    $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object Name -eq $name | Select-Object -First 1
    Invoke-Expression $definition.Extent.Text
}
function Write-Log { param($Message, $Level) }
$script:CleanupToken = [guid]::NewGuid().ToString('N')
$script:CleanupDir = Join-Path ([IO.Path]::GetTempPath()) ('StoreInstall-Packages-' + $script:CleanupToken)
$null = New-Item -ItemType Directory -Path $script:CleanupDir
try {
    Set-Content -LiteralPath (Join-Path $script:CleanupDir '.store-ltsc-owner') -Value 'someone-else'
    $null = Complete-Run 8
    Assert-True (Test-Path -LiteralPath $script:CleanupDir) 'Cleanup removed a directory owned by another run.'
    Set-Content -LiteralPath (Join-Path $script:CleanupDir '.store-ltsc-owner') -Value $script:CleanupToken
    $null = Complete-Run 0
    Assert-True (-not (Test-Path -LiteralPath $script:CleanupDir)) 'Cleanup did not remove the owned temporary directory.'
} finally {
    if (Test-Path -LiteralPath $script:CleanupDir) { Remove-Item -LiteralPath $script:CleanupDir -Recurse -Force }
}

$script:ScriptText = $installerText
$script:ScriptPath = 'C:\directory with spaces\install.ps1'
$script:BoundParams = @{ Source = 'Local'; WorkDir = 'C:\offline packages' }
$WorkDir = $script:BoundParams.WorkDir
# Mock only process creation. Capture and inspect the real snapshot before its cleanup.
function Start-Process {
    param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru)
    $bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($ArgumentList -split ' ')[-1]))
    Assert-True ($bootstrap -match "& '([^']+install\.ps1)' @parameters") 'Missing relaunch script path.'
    $snapshotPath = $Matches[1]
    Assert-True ((Get-Content -LiteralPath $snapshotPath -Raw) -ceq $installerText) 'Relaunch changed the executing revision.'
    Assert-True ($bootstrap -match "FromBase64String\('([^']+)'\)") 'Missing serialized parameters.'
    $parameters = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])))
    $script:CapturedParameters = $parameters
    $script:CapturedSnapshot = $snapshotPath
    [pscustomobject]@{ ExitCode = 5 }
}
$result = Invoke-Relaunch -Elevate
Assert-True ($result -eq 5) 'Relaunch lost the child exit code.'
Assert-True ($script:CapturedParameters.WorkDir -eq 'C:\offline packages') 'Relaunch lost a path containing spaces.'
Assert-True (-not (Test-Path -LiteralPath $script:CapturedSnapshot)) 'Relaunch snapshot was not cleaned up.'

# The elevated child starts in System32, so it must receive the already-resolved paths, not the typed relative ones.
$script:BoundParams = @{ Source = 'Local'; WorkDir = '.\pkgs'; LogDir = 'logs'; DownloadDir = 'downloads' }
$WorkDir = 'C:\resolved\pkgs'; $LogDir = 'C:\resolved\logs'; $DownloadDir = 'C:\resolved\downloads'
$null = Invoke-Relaunch -Elevate
Assert-True ($script:CapturedParameters.WorkDir -eq 'C:\resolved\pkgs' -and $script:CapturedParameters.LogDir -eq 'C:\resolved\logs' -and $script:CapturedParameters.DownloadDir -eq 'C:\resolved\downloads') 'Relaunch forwarded unresolved relative paths.'
$script:BoundParams = @{ Source = 'Local' }
$null = Invoke-Relaunch -Elevate
Assert-True ($script:CapturedParameters.WorkDir -eq 'C:\resolved\pkgs' -and -not $script:CapturedParameters.ContainsKey('DownloadDir')) 'Relaunch must forward the resolved WorkDir without inventing unbound options.'

# Exercise the native process boundary too. The invalid combination exits before any
# OS, admin, network, log, or package operation in the real Windows PowerShell child.
$script:BoundParams = @{ Source = 'Local'; DownloadOnly = $true; WorkDir = ''; SkipWinget = $false; ErrorAction = 'Stop' }
$WorkDir = ''
$result = Invoke-Relaunch
Assert-True ($result -eq 7) 'Real child relaunch lost serialized parameters or its exit code.'
Write-Host 'PASS: scope isolation, argument forwarding, owned cleanup, and revision-preserving relaunch.'
