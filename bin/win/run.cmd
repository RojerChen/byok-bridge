@echo off
rem BYOK CLI Hub official entry point.
rem Runtime environment is generated from the user config (or the bundled
rem config/providers.example.json on first run) and applied
rem to this CMD console through a temporary file under %TEMP%.
set "PSEXE=pwsh"
where pwsh >nul 2>nul
if errorlevel 1 set "PSEXE=powershell"

rem The source launcher lives in bin\win\, while install.cmd copies it next to
rem manager\. Resolve both layouts without generating a persistent config.
set "ROOT=%~dp0"
if not exist "%ROOT%manager\start-byok-cli-hub.ps1" set "ROOT=%~dp0..\..\"

set "ENV_FILE=%TEMP%\byok-cli-hub-env-%RANDOM%.cmd"

%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%ROOT%manager\start-byok-cli-hub.ps1" -EnvFile "%ENV_FILE%" %*
if errorlevel 1 (
    if exist "%ENV_FILE%" del /q "%ENV_FILE%"
    exit /b %errorlevel%
)

if not exist "%ENV_FILE%" (
    echo No environment settings were produced.
    exit /b 4
)

echo Applying BYOK CLI Hub environment in the current console...
call "%ENV_FILE%"
if exist "%ENV_FILE%" del /q "%ENV_FILE%"

if not defined __BYOK_CLI_COMMAND (
    set "__BYOK_CLI_COMMAND=copilot"
    set "__BYOK_CLI_ARGS=--experimental"
)

set "CLI_CMD="
for %%I in (%__BYOK_CLI_COMMAND%.cmd) do (
    where.exe %%I >nul 2>nul
    if not errorlevel 1 for /f "delims=" %%J in ('where.exe %%I 2^>nul') do set "CLI_CMD=%%J"
)
if not defined CLI_CMD (
    for %%I in (%__BYOK_CLI_COMMAND%) do (
        where.exe %%I >nul 2>nul
        if not errorlevel 1 for /f "delims=" %%J in ('where.exe %%I 2^>nul') do set "CLI_CMD=%%J"
    )
)
if not defined CLI_CMD (
    echo The '%__BYOK_CLI_COMMAND%' command was not found in PATH.
    exit /b 5
)

echo Launching %__BYOK_CLI_COMMAND%...
call "%CLI_CMD%" %__BYOK_CLI_ARGS%
set "EXIT_CODE=%errorlevel%"
set "__BYOK_CLI_COMMAND="
set "__BYOK_CLI_ARGS="
exit /b %EXIT_CODE%
