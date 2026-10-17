@setlocal DisableDelayedExpansion
@echo off
set "Path=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0\"
set "_psexe=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\reg.exe" (
  set "Path=%SystemRoot%\Sysnative;%SystemRoot%;%SystemRoot%\Sysnative\Wbem;%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\;%Path%"
  set "_psexe=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)

set "_ps1=%~dp0install.ps1"
set "_self=%~f0"
set "_args=%*"
set "_pause="

rem "__elevated" marks the copy started through UAC below: strip it and pause at the end so the window stays readable.
if "%~1"=="__elevated" (
  set "_pause=1"
  call set "_args=%%_args:~11%%"
)

if not exist "%_ps1%" (
  echo ERROR: Missing "%_ps1%"
  if defined _pause pause
  exit /b 7
)

whoami /groups 2>nul | findstr /i /c:"S-1-16-16384" /c:"S-1-16-12288" 1>nul
if not errorlevel 1 goto :elevated
if defined _pause (
  echo ERROR: Run this script as Administrator.
  pause
  exit /b 1
)
rem Not elevated: ask for admin rights via UAC (one-click use). Fails cleanly where no UAC prompt is possible.
echo Requesting administrator rights...
"%_psexe%" -NoLogo -NoProfile -NonInteractive -Command "try { $p = Start-Process -FilePath $env:ComSpec -ArgumentList ('/c \"\"' + $env:_self + '\" __elevated ' + $env:_args + '\"') -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { Write-Host 'ERROR: Run this script as Administrator (elevation was cancelled or is unavailable).'; exit 1 }"
exit /b %ERRORLEVEL%

:elevated
set "_build="
for /f "tokens=3" %%# in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| findstr /i /c:"CurrentBuildNumber"') do set "_build=%%#"
if not defined _build (
  echo ERROR: Unable to determine Windows build number.
  if defined _pause pause
  exit /b 7
)
if %_build% lss 19041 (
  echo ERROR: Requires Windows build 19041 or later.
  if defined _pause pause
  exit /b 2
)

rem Packages: local ones next to this script if present (-Source Auto), otherwise downloaded from Microsoft.
rem Options (-Source, -WorkDir, -DownloadDir, -DownloadOnly, -NoProvision, -SkipWinget, ...) pass through.
set "_src=-Source Auto"
echo( %_args% | findstr /i /c:"-Source" 1>nul && set "_src="
"%_psexe%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%_ps1%" %_src% %_args%
set "_rc=%ERRORLEVEL%"
if defined _pause (
  echo.
  echo Finished with exit code %_rc%.
  pause
)
exit /b %_rc%
