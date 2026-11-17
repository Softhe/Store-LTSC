@setlocal DisableDelayedExpansion
@echo off
set "Path=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0\"
set "_psexe=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\reg.exe" (
  set "Path=%SystemRoot%\Sysnative;%SystemRoot%;%SystemRoot%\Sysnative\Wbem;%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\;%Path%"
  set "_psexe=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)

set "_ps1=%~dp0install.ps1"
set "_args=%*"

if not exist "%_ps1%" (
  echo ERROR: Missing "%_ps1%"
  exit /b 7
)

rem Packages: local ones next to this script if present (-Source Auto), otherwise downloaded from Microsoft.
rem Options (-Source, -WorkDir, -DownloadDir, -DownloadOnly, -NoProvision, -SkipWinget, ...) pass through.
rem Match -Source only as a whole option (" -Source " or " -Source:"), not inside a path such as D:\my-source.
set "_src=-Source Auto"
echo( %_args% _| findstr /i /r /c:" -Source[ :]" 1>nul && set "_src="

rem In an administrator window the installer runs here, unattended. Otherwise it runs without -NonInteractive so
rem install.ps1 can ask for administrator rights (UAC) and continue in a new window. It passes on the options with
rem relative paths already resolved, and installs nothing without elevation (-DownloadOnly needs none).
set "_noni="
whoami /groups 2>nul | findstr /i /c:"S-1-16-16384" /c:"S-1-16-12288" 1>nul && set "_noni=-NonInteractive"
"%_psexe%" -NoLogo -NoProfile %_noni% -ExecutionPolicy Bypass -File "%_ps1%" %_src% %_args%
exit /b %ERRORLEVEL%
