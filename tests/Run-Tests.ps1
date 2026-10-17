#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File | Sort-Object Name)
if ($testFiles.Count -eq 0) { throw 'No regression tests found.' }
$engine = (Get-Process -Id $PID).Path
foreach ($file in $testFiles) {
    Write-Host "Running $($file.Name)"
    & $engine -NoLogo -NoProfile -NonInteractive -File $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "$($file.Name) failed with exit code $LASTEXITCODE." }
}
Write-Host "Passed $($testFiles.Count) regression test scripts."
