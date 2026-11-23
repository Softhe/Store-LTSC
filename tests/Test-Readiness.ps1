#Requires -Version 5.1
# Windows readiness checks, language-neutral deployment error codes, retry rules, the winget run check, diagnostics
# redaction and the validation of the newer options.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$installerPath = Join-Path $PSScriptRoot '..\install.ps1'
$installerText = Get-Content -LiteralPath $installerPath -Raw
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($installerText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$names = @('Invoke-SystemReadiness', 'Get-DeploymentErrorCode', 'Test-PermanentWebError', 'Invoke-WithRetry', 'Protect-DiagnosticText', 'Test-WingetCommand', 'Format-Brief', 'Format-ErrorText', 'Add-Failure')
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}
# The service and policy tables are plain assignments in the module body.
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in @('$script:StoreServices', '$script:StorePolicies') }, $true)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert { param($Condition, $Message) if (-not $Condition) { throw $Message } }
$script:Log = New-Object System.Collections.Generic.List[string]
function Write-Log { param($Message, $Level = 'INFO', [switch]$Quiet, $Console) $script:Log.Add("[$Level] $Message") }
function Write-Item { param($Status, $Text, $Note) $script:Log.Add("ITEM $Status $Text ($Note)") }
function Start-Sleep { param($Seconds, $Milliseconds) }

function Reset-State {
    param([hashtable] $Start = @{}, [hashtable] $Policies = @{}, [switch] $Fix, [string[]] $Unfixable = @(), [string[]] $RegistryOnly = @(), [string[]] $StillDisabled = @())
    $script:StartValues = $Start; $script:PolicyValues = $Policies; $script:Unfixable = $Unfixable
    $script:RegistryOnly = $RegistryOnly; $script:StillDisabled = $StillDisabled; $script:RestartRequired = $false
    $script:FixServices = [bool]$Fix; $script:Fixed = New-Object System.Collections.Generic.List[string]
    $script:Advisories = New-Object System.Collections.Generic.List[string]
    $script:FailCount = 0; $script:Failures = New-Object System.Collections.Generic.List[string]
    $script:IsSystem = $false; $script:WingetLicenseMissing = $false; $script:Log.Clear()
}
function Get-ServiceStartValue { param($Name) if ($script:StartValues.ContainsKey($Name)) { $script:StartValues[$Name] } else { 3 } }
# RegistryOnly: the service manager refuses the change (AppXSvc, ClipSVC, DoSvc for an administrator), so only the
# registry changes and Windows applies it after a restart. StillDisabled: the registry says Manual, Windows disagrees.
function Set-ServiceManual { param($Name) if ($script:Unfixable -contains $Name) { throw 'Access is denied' }; $script:Fixed.Add($Name); $script:StartValues[$Name] = 3; return ($script:RegistryOnly -notcontains $Name) }
function Test-ServiceCanStart { param($Name) ($script:StillDisabled -notcontains $Name) -and ($script:RegistryOnly -notcontains $Name -or $script:Fixed -notcontains $Name) }
function Get-PolicyValue { param($Hive, $Key, $Name) $script:PolicyValues["$Hive|$Name"] }

# 1. Services and policies.
Reset-State
Assert (Invoke-SystemReadiness) 'A system with every service enabled must be ready.'
Assert ($script:Advisories.Count -eq 0 -and ($script:Log -match '^ITEM OK Services')) 'A healthy system gets one OK line and no advisories.'

Reset-State -Start @{ wuauserv = 4; DoSvc = 4 }
Assert (Invoke-SystemReadiness) 'Disabled download services must not stop the install.'
Assert ($script:Advisories.Count -eq 2 -and $script:Advisories[0] -match '-FixServices') 'Each disabled optional service must become an advisory that names -FixServices.'
Assert ($script:FailCount -eq 0) 'Advisories are not failures.'

Reset-State -Start @{ AppXSvc = 4 }
Assert (-not (Invoke-SystemReadiness)) 'A disabled AppX Deployment Service must stop the install.'
Assert ($script:Log -match '^ITEM FAIL AppX Deployment Service') 'A disabled required service must be a FAIL line.'

Reset-State -Start @{ AppXSvc = 4; wuauserv = 4 } -Fix
Assert (Invoke-SystemReadiness) '-FixServices must make a system with disabled services ready.'
Assert (($script:Fixed -join ',') -eq 'AppXSvc,wuauserv' -and $script:Advisories.Count -eq 0) '-FixServices must re-enable exactly the disabled services.'

Reset-State -Start @{ StateRepository = 4 } -Fix -Unfixable StateRepository
Assert (-not (Invoke-SystemReadiness)) 'A required service that cannot be re-enabled must stop the install.'
Assert (-not $script:RestartRequired) 'A service that could not be changed at all does not need a restart.'

# The 2026-11-23 LTSC 2024 VM: the service manager refused AppXSvc, ClipSVC and DoSvc, only their registry values
# changed, and the first deployment failed with "The service cannot be started ... because it is disabled".
Reset-State -Start @{ AppXSvc = 4; ClipSVC = 4; DoSvc = 4; InstallService = 4 } -Fix -RegistryOnly AppXSvc, ClipSVC, DoSvc
Assert (-not (Invoke-SystemReadiness)) 'A required service that changes only after a restart must stop the install.'
Assert ($script:RestartRequired -and ($script:Log -match '^ITEM FAIL AppX Deployment Service \(set to Manual; Windows applies this when it restarts\)')) 'The FAIL line must say that Windows applies the change when it restarts.'
Assert (($script:Fixed -join ',') -eq 'AppXSvc,ClipSVC,InstallService,DoSvc') 'Every disabled service must still be changed, so one restart is enough.'
Reset-State -Start @{ ClipSVC = 4; DoSvc = 4 } -Fix -RegistryOnly ClipSVC, DoSvc
Assert (Invoke-SystemReadiness) 'Optional services that change after a restart must not stop the install.'
Assert (($script:Log -match 'ITEM OK Client License Service \(was disabled, now Manual after Windows restarts\)') -and $script:Advisories.Count -eq 1 -and $script:Advisories[0] -match '^Restart Windows') 'They must say so, with one restart advisory.'
# A rerun before that restart: the registry says Manual, but Windows still refuses to start the service.
Reset-State -StillDisabled AppXSvc
Assert (-not (Invoke-SystemReadiness)) 'A required service Windows still treats as disabled must stop the install.'
Assert ($script:RestartRequired -and ($script:Log -match '^ITEM FAIL AppX Deployment Service \(Windows treats it as disabled until it restarts\)')) 'It must ask for a restart.'

Reset-State -Start @{ ClipSVC = $null }
Assert (Invoke-SystemReadiness) 'A missing optional service must not stop the install.'
Assert ($script:Advisories[0] -match 'missing' -and $script:Advisories[0] -notmatch '-FixServices') 'A missing service cannot be fixed by -FixServices and must not suggest it.'

Reset-State -Policies @{ 'CurrentUser|RemoveWindowsStore' = 1; 'LocalMachine|DoNotConnectToWindowsUpdateInternetLocations' = 1; 'LocalMachine|DisableStoreApps' = 0 }
Assert (Invoke-SystemReadiness) 'Policies must not stop the install.'
Assert ($script:Advisories.Count -eq 2 -and ($script:Advisories -match 'HKCU\\SOFTWARE\\Policies\\Microsoft\\WindowsStore\\RemoveWindowsStore') -and ($script:Advisories -match 'DoNotConnectToWindowsUpdateInternetLocations')) 'Each policy set to 1 must be an advisory with its registry path.'
Reset-State -Policies @{ 'CurrentUser|RemoveWindowsStore' = 1 }
$script:IsSystem = $true
$null = Invoke-SystemReadiness
Assert ($script:Advisories.Count -eq 0) "As SYSTEM, the SYSTEM account's own user policies are not checked."
Reset-State
$null = Invoke-SystemReadiness -InstallationType Server
Assert ($script:Log -match '^ITEM WARN Windows Server') 'Windows Server must be reported as untested.'
Write-Host 'PASS: disabled services, -FixServices, missing services, Store policies and Windows Server are reported correctly.'

# 2. Deployment error codes do not depend on the language of the error text.
$deployment = New-Object IO.FileNotFoundException 'Distribution misslyckades med HRESULT: 0x80073d06, Ett paket med en hogre version ar redan installerat.'
Assert ((Get-DeploymentErrorCode $deployment) -eq '0x80073D06') 'The deployment HRESULT in a localized message must be found.'
$com = New-Object Runtime.InteropServices.COMException 'Element hittades inte.', ([int]-2147023728)
Assert ((Get-DeploymentErrorCode $com) -eq '0x80070490') 'Without a code in the text, the exception HResult must be used.'
$plain = $null; try { throw 'Element not found.' } catch { $plain = $_ }
Assert ($null -eq (Get-DeploymentErrorCode $plain)) 'A generic PowerShell exception has no deployment code.'
$wrapped = New-Object Management.Automation.MethodInvocationException 'Exception calling "Invoke"', $deployment
Assert ((Get-DeploymentErrorCode $wrapped) -eq '0x80073D06') 'The code of an inner exception must be found.'
Write-Host 'PASS: deployment error codes are read independently of the Windows display language.'

# 3. Retries: a permanent HTTP client error fails at once; server errors are retried.
$server = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$server.Start()
$hits = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
$serverShell = [powershell]::Create().AddScript({
    param($listener, $hits)
    while ($true) {
        try { $client = $listener.AcceptTcpClient() } catch { break }
        try {
            $stream = $client.GetStream(); $reader = New-Object IO.StreamReader($stream)
            $path = (($reader.ReadLine()) -split ' ')[1]
            while (($line = $reader.ReadLine())) { }
            $null = $hits.Add($path)
            $status = if ($path -eq '/missing') { '404 Not Found' } else { '503 Service Unavailable' }
            $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        } catch { } finally { $client.Close() }
    }
}).AddArgument($server).AddArgument($hits)
$null = $serverShell.BeginInvoke()
try {
    $base = "http://127.0.0.1:$($server.LocalEndpoint.Port)"
    foreach ($case in @(@('/missing', 1, $false), @('/busy', 3, $false), @('/missing', 3, $true))) {
        $hits.Clear()
        $failed = $false
        try { $null = Invoke-WithRetry -What 'test' -RetryAll:$case[2] -Action { Invoke-WebRequest -Uri ($base + $case[0]) -UseBasicParsing -TimeoutSec 10 } } catch { $failed = $true }
        Assert ($failed -and $hits.Count -eq $case[1]) "$($case[0]) (RetryAll $($case[2])) expected $($case[1]) request(s), got $($hits.Count)."
    }
} finally { $server.Stop(); $serverShell.Dispose() }
Write-Host 'PASS: HTTP 4xx fails at once, 5xx is retried, and -RetryAll retries everything.'

# 4. The winget run check.
Reset-State
function Invoke-Winget { param($Arguments, $TimeoutSeconds) [pscustomobject]@{ ExitCode = 0; Output = 'v1.30.310' } }
Assert (Test-WingetCommand) 'A winget that prints its version runs.'
Assert ($script:Log -match '^ITEM OK winget v1\.30\.310 runs') 'The OK line must show the winget version.'
function Invoke-Winget { param($Arguments, $TimeoutSeconds) throw 'No applicable app licenses found.' }
Reset-State
Assert (-not (Test-WingetCommand)) 'A winget Windows refuses to start does not run.'
Assert ($script:FailCount -eq 1 -and $script:Failures[0] -match 'licenses') 'A winget that does not run is a partial failure with the reason.'
Reset-State; $script:WingetLicenseMissing = $true
$null = Test-WingetCommand
Assert ($script:FailCount -eq 0) 'A missing license is counted once, not again when winget then fails.'
function Invoke-Winget { param($Arguments, $TimeoutSeconds) $null }
Reset-State
Assert (-not (Test-WingetCommand) -and $script:Failures[0] -match 'not available') 'A missing winget alias is reported.'
Write-Host 'PASS: winget is run once after installation and a failure is reported once.'

# 5. Diagnostics text loses user, computer and domain names and account SIDs.
$saved = @{ USERNAME = $env:USERNAME; COMPUTERNAME = $env:COMPUTERNAME; USERDOMAIN = $env:USERDOMAIN; USERPROFILE = $env:USERPROFILE }
try {
    $env:USERNAME = 'Administrator'; $env:COMPUTERNAME = 'DESK-42'; $env:USERDOMAIN = 'CONTOSO'; $env:USERPROFILE = 'C:\Users\Administrator'
    $text = Protect-DiagnosticText 'User CONTOSO\Administrator on desk-42, profile C:\Users\Administrator\AppData, SID S-1-5-21-1111-2222-3333-1001, group BUILTIN\Administrators'
    Assert ($text -notmatch 'CONTOSO|DESK-42|S-1-5-21' -and $text -notmatch '\\Administrator\b') "Names must be removed, got: $text"
    Assert ($text -match '%USERPROFILE%\\AppData' -and $text -match 'BUILTIN\\Administrators') "Placeholders must keep the text readable and unrelated words intact, got: $text"
} finally { foreach ($kv in $saved.GetEnumerator()) { Set-Item -Path "Env:$($kv.Key)" -Value $kv.Value } }
Write-Host 'PASS: diagnostics text is redacted.'

# 6. Option combinations that cannot work are rejected before any system change.
Remove-Item Function:\Start-Sleep
foreach ($case in @(
        @{ TargetBuild = 19044 },
        @{ DownloadOnly = $true; TargetArch = 'arm' },
        @{ DownloadOnly = $true; TargetBuild = 7601 },
        @{ CollectLogs = $true; DownloadOnly = $true },
        @{ CollectLogs = $true; FixServices = $true })) {
    & ([scriptblock]::Create($installerText)) @case *> $null
    Assert ($LASTEXITCODE -eq 7) "Options $(($case.Keys | Sort-Object) -join ', ') must be rejected with exit code 7, got $LASTEXITCODE."
}
Assert ($installerText -match "\`$StoreLtscVersion = '\d+\.\d+\.\d+'") 'install.ps1 must declare its release version.'
Write-Host 'PASS: invalid option combinations are rejected and the script declares its version.'
