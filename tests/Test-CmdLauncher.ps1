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

    # The launcher itself: run the real Install-Store.cmd against a stand-in install.ps1 that records what it got.
    # Options must arrive unchanged (quotes, spaces, percent signs). -NonInteractive is passed only in an
    # administrator window; otherwise install.ps1 must be free to ask for elevation itself.
    $kit = Join-Path $temp 'kit 50%off'
    $null = New-Item -ItemType Directory -Path $kit
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\Install-Store.cmd') -Destination $kit
    Set-Content -LiteralPath (Join-Path $kit 'install.ps1') -Encoding ASCII -Value @'
$noni = @([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }).Count -gt 0
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'seen.txt'), ((@($args) | ForEach-Object { "<$_>" }) -join '') + "|noni=$noni")
exit 3
'@
    $wrapper = Join-Path $kit 'probe.cmd'
    # No "call": that would expand percent signs in the options a second time.
    [IO.File]::WriteAllText($wrapper, "@echo off`r`n`"%~dp0Install-Store.cmd`" %STORE_LTSC_TEST_ARGS%`r`n")
    $elevated = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    function Get-LauncherView([string] $Arguments) {
        $env:STORE_LTSC_TEST_ARGS = $Arguments
        try { $null = & cmd.exe /d /c "`"$wrapper`""; $code = $LASTEXITCODE } finally { Remove-Item Env:STORE_LTSC_TEST_ARGS -ErrorAction SilentlyContinue }
        Assert-True ($code -eq 3) "The launcher must return the installer's exit code, got $code."
        (Get-Content -LiteralPath (Join-Path $kit 'seen.txt') -Raw).Trim()
    }
    $noni = "|noni=$elevated"
    Assert-True ((Get-LauncherView '') -eq "<-Source><Auto>$noni") "No options must run with -Source Auto, got '$(Get-LauncherView '')'."
    Assert-True ((Get-LauncherView '-SkipWinget -WorkDir ".\my pkgs"') -eq "<-Source><Auto><-SkipWinget><-WorkDir><.\my pkgs>$noni") 'Quoted options must arrive unchanged.'
    Assert-True ((Get-LauncherView '-WorkDir "D:\50%off" -Source Local') -eq "<-WorkDir><D:\50%off><-Source><Local>$noni") 'A percent sign in an option must arrive unchanged.'
    Assert-True ((Get-LauncherView '-DownloadOnly:$false') -eq "<-Source><Auto><-DownloadOnly><`$false>$noni") 'A switch value must reach install.ps1, which decides about elevation.'
    Write-Host "PASS: the launcher passes options unchanged and leaves elevation to install.ps1 (tested $(if ($elevated) { 'elevated' } else { 'not elevated' }))."
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
