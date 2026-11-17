#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
function Assert-True($Value, $Message) { if (-not $Value) { throw $Message } }

# Run the launcher's actual -Source detection line in an isolated batch file.
$launcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Install-Store.cmd')
$detection = @($launcher | Where-Object { $_ -match '^echo\( %_args% .*findstr' })
Assert-True ($detection.Count -eq 1) 'Launcher -Source detection line not found.'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('store-cmd-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
try {
    $probe = Join-Path $temp 'probe.cmd'
    # Arguments arrive through the environment, avoiding engine-specific native quoting of embedded quotes.
    [IO.File]::WriteAllText($probe, ((@('@echo off', 'set "_args=%STORE_LTSC_TEST_ARGS%"', 'set "_src=-Source Auto"') + $detection + 'echo [%_src%]') -join "`r`n") + "`r`n")
    function Get-SourceDefault([string] $Arguments) {
        $env:STORE_LTSC_TEST_ARGS = $Arguments
        try { & cmd.exe /d /c $probe | Select-Object -Last 1 } finally { Remove-Item Env:STORE_LTSC_TEST_ARGS -ErrorAction SilentlyContinue }
    }
    Assert-True ((Get-SourceDefault '') -eq '[-Source Auto]') 'No options must default to -Source Auto.'
    Assert-True ((Get-SourceDefault '-WorkDir D:\my-source-pkgs') -eq '[-Source Auto]') 'A path containing "-source" must not suppress -Source Auto.'
    Assert-True ((Get-SourceDefault '-SkipWinget -Sourcery') -eq '[-Source Auto]') 'A longer option name must not suppress -Source Auto.'
    Assert-True ((Get-SourceDefault '-Source Online') -eq '[]') 'An explicit -Source must replace the default.'
    Assert-True ((Get-SourceDefault '-SkipWinget -source:Local') -eq '[]') 'An explicit -Source:value must replace the default.'
    Assert-True ((Get-SourceDefault '-WorkDir "D:\Store Pkgs" -Source Local') -eq '[]') 'An explicit -Source after a quoted path must replace the default.'
    Write-Host 'PASS: launcher applies -Source Auto unless -Source is given as an option.'

    # The UAC relaunch: build the launcher's own command line (without -Verb RunAs) and run its own argument
    # handling. The elevated copy must return to the starting folder and receive the options unchanged.
    $first = [array]::IndexOf($launcher, 'set "_args=%*"'); $last = [array]::IndexOf($launcher, ':args_ready')
    Assert-True ($first -ge 0 -and $last -gt $first) 'Launcher argument handling not found.'
    $self = Join-Path $temp 'self.cmd'
    [IO.File]::WriteAllText($self, ((@('@setlocal DisableDelayedExpansion', '@echo off', 'set "_pause="') + $launcher[$first..$last] + @('>"%~dp0seen.txt" echo %CD%^|%_args%^|%_pause%')) -join "`r`n") + "`r`n")
    $relaunch = @($launcher | Where-Object { $_ -match 'Start-Process -FilePath' })
    Assert-True ($relaunch.Count -eq 1 -and $relaunch[0] -match '-ArgumentList (\(.+?\)) -Verb RunAs') 'Launcher UAC relaunch line not found.'
    $expression = $Matches[1] -replace '\\"', '"'
    $work = Join-Path $temp 'work dir 50%off'
    $null = New-Item -ItemType Directory -Path $work
    function Get-ElevatedView([string] $Arguments) {
        $env:_self = $self; $env:_args = $Arguments
        Push-Location -LiteralPath $work
        try { $null = Start-Process -FilePath $env:ComSpec -ArgumentList (Invoke-Expression $expression) -NoNewWindow -Wait -PassThru }
        finally { Pop-Location; $env:_self = $null; $env:_args = $null }
        (Get-Content -LiteralPath (Join-Path $temp 'seen.txt') -Raw).Trim()
    }
    Assert-True ((Get-ElevatedView '') -eq "$work||1") 'The elevated copy must start in the original folder with no options.'
    Assert-True ((Get-ElevatedView '-SkipWinget -WorkDir ".\my pkgs"') -eq "$work|-SkipWinget -WorkDir `".\my pkgs`"|1") 'The elevated copy must receive quoted options unchanged.'
    Assert-True ((Get-ElevatedView '-WorkDir "D:\50%off"') -eq "$work|-WorkDir `"D:\50%off`"|1") 'A percent sign in an option must survive the relaunch.'
    Write-Host 'PASS: the elevated launcher copy keeps the starting folder and its options.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
