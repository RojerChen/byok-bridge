@echo off
setlocal
rem Launch the CLI inside PowerShell so API keys never pass through a temporary
rem CMD file and never persist in the caller's CMD environment.

set "PSEXE=pwsh"
where pwsh >nul 2>nul
if errorlevel 1 set "PSEXE=powershell"

set "ROOT=%~dp0"
if not exist "%ROOT%manager\start-byok-cli-hub.ps1" set "ROOT=%~dp0..\..\"

%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manager\start-byok-cli-hub.ps1" %*
set "EXIT_CODE=%errorlevel%"
endlocal & exit /b %EXIT_CODE%
