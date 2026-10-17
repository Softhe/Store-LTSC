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
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
