#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$names = @('Write-Log', 'Write-StatusLine', 'Show-Progress', 'Clear-Progress')
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}
function Assert { param($Condition, $Message) if (-not $Condition) { throw $Message } }
$script:StatusColors = @{ OK = 'Green'; SKIP = 'DarkCyan'; WARN = 'Yellow'; FAIL = 'Red' }
$script:ActiveProgress = $null
$script:Shown = New-Object System.Collections.Generic.List[string]
function Write-Host { param([object]$Object, $ForegroundColor, [switch]$NoNewline) $script:Shown.Add([string]$Object) }
$script:ProgressCalls = New-Object System.Collections.Generic.List[string]
function Write-Progress { param($Activity, $Status, $PercentComplete, [switch]$Completed) $script:ProgressCalls.Add("$Activity|$Completed") }

# 1. Details hidden from the console must not be lost when the log file cannot be written.
$folder = Join-Path ([IO.Path]::GetTempPath()) ('store-console-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $folder
try {
    $script:LogFile = Join-Path $folder 'run.log'
    Write-Log 'saved detail' -Quiet
    Write-Log 'full saved error' 'ERROR' -Console 'short error'
    Assert ((Get-Content -LiteralPath $script:LogFile -Raw) -match 'saved detail') 'A quiet message must be written to the log file.'
    Assert (-not ($script:Shown -match 'saved detail') -and ($script:Shown -contains 'short error')) 'With a log file, quiet messages stay off the console and -Console text is shown.'

    $script:Shown.Clear()
    $script:LogFile = Join-Path $folder 'missing\run.log'
    Write-Log 'unsaved deployment error' 'ERROR' -Quiet
    Write-Log 'full unsaved error' 'ERROR' -Console 'short'
    Assert ($script:Shown -contains 'unsaved deployment error') 'A quiet message that could not be saved must be shown on the console.'
    Assert ($script:Shown -contains 'full unsaved error') 'An unsaved message must be shown in full, not shortened.'

    $script:Shown.Clear()
    $script:LogFile = $null
    Write-Log 'no log file' -Quiet
    Assert ($script:Shown -contains 'no log file') 'Without a log file, quiet messages must be shown.'
} finally { Remove-Item -LiteralPath $folder -Recurse -Force }

# 2. Progress bars left open by an error are closed.
try {
    Show-Progress -Activity 'Downloading packages from Microsoft' -Status 'Store'
    throw 'download failed'
} catch { Clear-Progress }
Assert ($script:ProgressCalls[-1] -eq 'Downloading packages from Microsoft|True') 'An interrupted progress bar must be closed.'
Assert ($script:ActiveProgress.Count -eq 0) 'No progress bar may remain active after cleanup.'
$script:ProgressCalls.Clear()
Clear-Progress
Assert ($script:ProgressCalls.Count -eq 0) 'Cleanup must not touch progress bars that are already closed.'

[Console]::WriteLine('PASS: unsaved log details reach the console, and interrupted progress bars are closed.')
