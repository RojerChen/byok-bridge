@echo off
rem uninstall.cmd - Node.js uninstaller for BYOK Bridge.
rem Requires Node.js 22 or later.

setlocal
where node >nul 2>nul
if errorlevel 1 (
    echo Error: Node.js was not found in PATH.
    echo BYOK Bridge requires Node.js 22 or later. Install from https://nodejs.org/
    endlocal & exit /b 1
)
set "_BYOK_BRIDGE_UNINSTALLER=%~dp0manager\windows-uninstaller-cli.mjs"
if not exist "%_BYOK_BRIDGE_UNINSTALLER%" set "_BYOK_BRIDGE_UNINSTALLER=%~dp0..\..\manager\windows-uninstaller-cli.mjs"
if not exist "%_BYOK_BRIDGE_UNINSTALLER%" (
    echo Error: Could not locate manager\windows-uninstaller-cli.mjs relative to uninstall.cmd.
    endlocal & exit /b 1
)
node "%_BYOK_BRIDGE_UNINSTALLER%" %*
set "EXIT_CODE=%errorlevel%"
endlocal & exit /b %EXIT_CODE%
