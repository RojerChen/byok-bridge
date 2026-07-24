@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set "EXIT_CODE=%errorlevel%"
endlocal & exit /b %EXIT_CODE%
