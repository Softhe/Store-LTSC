#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$names = @('Write-Log', 'Write-StatusLine', 'Write-Item', 'Write-LiveLine', 'Clear-LiveLine', 'Restore-Console', 'Show-Activity', 'Get-ConsoleWidth', 'Format-Clock', 'Format-Duration', 'Split-Line', 'Invoke-Deployment')
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $names) { . ([scriptblock]::Create($node.Extent.Text)) }
}
function Assert { param($Condition, $Message) if (-not $Condition) { throw $Message } }
$script:StatusColors = @{ OK = 'Green'; SKIP = 'DarkCyan'; WARN = 'Yellow'; FAIL = 'Red' }
$script:LiveUi = $false; $script:LiveLength = 0; $script:CursorHidden = $false
$script:Glyph = @{ Full = '#'; Empty = '-'; Rule = '=' }
$script:Spinner = '|', '/', '-', '\'
$script:RunTimer = [Diagnostics.Stopwatch]::StartNew()
$script:Shown = New-Object System.Collections.Generic.List[string]
function Write-Host { param([object]$Object, $ForegroundColor, [switch]$NoNewline) $script:Shown.Add([string]$Object) }
function Get-ConsoleWidth { 100 }

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
    Write-Log 'later detail' -Quiet
    Assert ($script:Shown -contains 'unsaved deployment error') 'A quiet message that could not be saved must be shown on the console.'
    Assert ($script:Shown -contains 'full unsaved error') 'An unsaved message must be shown in full, not shortened.'
    Assert ($script:Shown -contains 'later detail') 'After the log file fails, later details must keep reaching the console.'
    Assert (@($script:Shown -match 'Log file is not writable').Count -eq 1) 'A failing log file must be reported once, not for every line.'

    $script:Shown.Clear()
    $script:LogFile = $null
    Write-Log 'no log file' -Quiet
    Assert ($script:Shown -contains 'no log file') 'Without a log file, quiet messages must be shown.'

    # A long error gets its own wrapped lines instead of running off the result row.
    $script:Shown.Clear()
    $script:LogFile = Join-Path $folder 'run.log'
    Write-Item FAIL 'Microsoft Store' ('deployment failed ' * 20)
    Assert (@($script:Shown | Where-Object { $_.Length -gt 100 }).Count -eq 0) 'Failure details must be wrapped to the window width.'
    Assert (@($script:Shown -match 'deployment failed').Count -ge 3) 'Failure details must be shown in full across several lines.'
} finally { Remove-Item -LiteralPath $folder -Recurse -Force }

# 2. Redirected output: nothing transient is drawn.
$script:Shown.Clear()
Show-Activity -Text 'Microsoft Store' -Fraction 0.5 -Detail '60.0 / 120.0 MB'
Assert ($script:Shown.Count -eq 0) 'Without a console window no progress line may be written.'

# 3. Console window: the progress line is drawn in place, cut to the window width, and erased before a result line.
$script:LiveUi = $true
Show-Activity -Text 'Microsoft Store' -Fraction 0.5 -Detail @('60.0/120.0 MB', '12.0 MB/s', ('x' * 200))
$drawn = ($script:Shown -join '')
Assert ($drawn.StartsWith("`r")) 'The progress line must return to the start of the row instead of adding a new one.'
Assert ($drawn -match 'Microsoft Store' -and $drawn -match '#{5}-{5}' -and $drawn -match ' 50%') 'The progress line must show the name, a half-filled bar and the percentage.'
Assert (($drawn.Length - 1) -le 99 -and $script:LiveLength -le 99) 'The progress line must never wrap.'
Assert ($drawn -match '60\.0/120\.0 MB  12\.0 MB/s' -and $drawn -notmatch 'xxx') 'Detail parts that do not fit are left out whole, not cut.'
$script:Shown.Clear()
Write-StatusLine 'OK' 'Microsoft Store'
Assert ($script:Shown[0] -match "^`r +`r$" -and $script:LiveLength -eq 0) 'A result line must first erase the progress line.'

# 4. A deployment cmdlet runs on a second runspace while progress is drawn; its result and errors come back.
$script:Shown.Clear()
Invoke-Deployment -Command 'Start-Sleep' -Parameters @{ Milliseconds = 400 } -Activity 'Microsoft Store' -Detail '1 of 4, adding for new users'
Assert (@($script:Shown -match 'adding for new users').Count -ge 2) 'A running deployment must keep redrawing its progress line.'
$message = ''
try { Invoke-Deployment -Command 'Get-Item' -Parameters @{ LiteralPath = (Join-Path $folder 'gone') } -Activity 'x' } catch { $message = $_.Exception.Message }
Assert ($message -match 'gone') "A deployment error must surface as an exception with the cmdlet's message, got '$message'."
$message = ''
try { Invoke-Deployment -Command 'Get-Item' -Parameters @{ NoSuchParameter = 1 } -Activity 'x' } catch { $message = $_.Exception.Message }
Assert ($message -match 'NoSuchParameter' -and $message -notmatch 'EndInvoke') "A terminating error must be reported without the runspace wrapper, got '$message'."
Restore-Console
$script:LiveUi = $false
$script:Called = $null
function Add-TestPackage { param($Path) $script:Called = $Path }
Invoke-Deployment -Command 'Add-TestPackage' -Parameters @{ Path = 'direct' }
Assert ($script:Called -eq 'direct') 'Without a console window the deployment cmdlet is called directly.'

[Console]::WriteLine('PASS: unsaved log details reach the console, failures wrap, and progress is drawn in place only in a console window.')
