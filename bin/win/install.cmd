@echo off
rem install.cmd - Node.js installer for BYOK Bridge.
rem Requires Node.js 22 or later.

setlocal
where node >nul 2>nul
if errorlevel 1 (
    echo Error: Node.js was not found in PATH.
    echo BYOK Bridge requires Node.js 22 or later. Install from https://nodejs.org/
    endlocal & exit /b 1
)
for /f "tokens=*" %%v in ('node --version 2^>nul') do set "_BYOK_NODE_VER=%%v"
set "_BYOK_NODE_VER=%_BYOK_NODE_VER:v=%"
for /f "tokens=1 delims=." %%m in ("%_BYOK_NODE_VER%") do set "_BYOK_NODE_MAJOR=%%m"
if "%_BYOK_NODE_MAJOR%"=="" (
    echo Error: Could not determine Node.js version.
    endlocal & exit /b 1
)
if %_BYOK_NODE_MAJOR% LSS 22 (
    echo Error: Node.js 22 or later is required. Current version: %_BYOK_NODE_VER%
    echo Install the latest LTS release from https://nodejs.org/
    endlocal & exit /b 1
)
node "%~dp0..\..\manager\windows-installer-cli.mjs" %*
set "EXIT_CODE=%errorlevel%"
endlocal & exit /b %EXIT_CODE%
