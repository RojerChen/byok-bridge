@echo off
rem run.cmd - Windows launcher for BYOK Bridge.
rem Calls the Node.js manager to resolve the execution plan, then applies the
rem resulting environment to this caller CMD console and launches the CLI.
rem
rem Node.js 22 or later is required. Install from https://nodejs.org/

rem --- Node.js preflight check ---------------------------------------------
where node >nul 2>nul
if errorlevel 1 (
    echo Error: Node.js was not found in PATH.
    echo BYOK Bridge requires Node.js 22 or later. Install from https://nodejs.org/
    exit /b 1
)
for /f "tokens=*" %%v in ('node --version 2^>nul') do set "_BYOK_NODE_VER=%%v"
set "_BYOK_NODE_VER=%_BYOK_NODE_VER:v=%"
for /f "tokens=1 delims=." %%m in ("%_BYOK_NODE_VER%") do set "_BYOK_NODE_MAJOR=%%m"
if "%_BYOK_NODE_MAJOR%"=="" (
    echo Error: Could not determine Node.js version.
    set "_BYOK_NODE_VER=" & set "_BYOK_NODE_MAJOR="
    exit /b 1
)
if %_BYOK_NODE_MAJOR% LSS 22 (
    echo Error: Node.js 22 or later is required. Current version: %_BYOK_NODE_VER%
    echo Install the latest LTS release from https://nodejs.org/
    set "_BYOK_NODE_VER=" & set "_BYOK_NODE_MAJOR="
    exit /b 1
)
set "_BYOK_NODE_VER=" & set "_BYOK_NODE_MAJOR="

rem --- Locate manager.mjs --------------------------------------------------
rem Installed snapshots place run.cmd beside manager. A repository checkout
rem keeps it under bin\win\, two levels below the repository root.
set "_BYOK_BRIDGE_MANAGER=%~dp0manager\manager.mjs"
if not exist "%_BYOK_BRIDGE_MANAGER%" set "_BYOK_BRIDGE_MANAGER=%~dp0..\..\manager\manager.mjs"
if not exist "%_BYOK_BRIDGE_MANAGER%" (
    echo Error: Could not locate manager\manager.mjs relative to run.cmd.
    exit /b 1
)

rem --- Prepare the CMD plan temp file -------------------------------------
set "_BYOK_BRIDGE_CMD_PLAN=%TEMP%\byok-bridge-plan-%RANDOM%-%RANDOM%.cmd"
set "__BYOK_BRIDGE_ACTION="
set "__BYOK_BRIDGE_EXECUTABLE="
set "__BYOK_BRIDGE_ARGUMENTS="
set "__BYOK_BRIDGE_CLI_ID="

node "%_BYOK_BRIDGE_MANAGER%" --internal-cmd-plan-file "%_BYOK_BRIDGE_CMD_PLAN%" %*
set "_BYOK_BRIDGE_MANAGER_EXIT=%errorlevel%"
if not "%_BYOK_BRIDGE_MANAGER_EXIT%"=="0" goto :manager_failed
if not exist "%_BYOK_BRIDGE_CMD_PLAN%" goto :missing_plan

call "%_BYOK_BRIDGE_CMD_PLAN%"
set "_BYOK_BRIDGE_PLAN_EXIT=%errorlevel%"
del /q "%_BYOK_BRIDGE_CMD_PLAN%" >nul 2>nul
set "_BYOK_BRIDGE_CMD_PLAN="
if not "%_BYOK_BRIDGE_PLAN_EXIT%"=="0" goto :plan_failed
if /i "%__BYOK_BRIDGE_ACTION%"=="none" goto :success
if /i not "%__BYOK_BRIDGE_ACTION%"=="launch" goto :invalid_plan
if not defined __BYOK_BRIDGE_EXECUTABLE goto :invalid_plan

echo Applying BYOK environment in the current CMD console...
echo Launching %__BYOK_BRIDGE_CLI_ID%...
call "%__BYOK_BRIDGE_EXECUTABLE%" %__BYOK_BRIDGE_ARGUMENTS%
set "_BYOK_BRIDGE_EXIT=%errorlevel%"
if /i "%__BYOK_BRIDGE_CLI_ID%"=="opencode" if not "%_BYOK_BRIDGE_EXIT%"=="0" (
    echo OpenCode exited with code %_BYOK_BRIDGE_EXIT%. Generated config: %OPENCODE_CONFIG%
    echo Check the merged configuration with: opencode debug config
)
goto :cleanup

:manager_failed
if exist "%_BYOK_BRIDGE_CMD_PLAN%" del /q "%_BYOK_BRIDGE_CMD_PLAN%" >nul 2>nul
set "_BYOK_BRIDGE_EXIT=%_BYOK_BRIDGE_MANAGER_EXIT%"
goto :cleanup

:missing_plan
echo No caller CMD environment plan was produced.
set "_BYOK_BRIDGE_EXIT=4"
goto :cleanup

:plan_failed
echo The caller CMD environment plan could not be applied.
set "_BYOK_BRIDGE_EXIT=%_BYOK_BRIDGE_PLAN_EXIT%"
goto :cleanup

:invalid_plan
echo The caller CMD environment plan was invalid.
set "_BYOK_BRIDGE_EXIT=4"
goto :cleanup

:success
set "_BYOK_BRIDGE_EXIT=0"

:cleanup
set "_BYOK_BRIDGE_RETURN=%_BYOK_BRIDGE_EXIT%"
set "_BYOK_BRIDGE_MANAGER="
set "_BYOK_BRIDGE_CMD_PLAN="
set "_BYOK_BRIDGE_MANAGER_EXIT="
set "_BYOK_BRIDGE_PLAN_EXIT="
set "__BYOK_BRIDGE_ACTION="
set "__BYOK_BRIDGE_EXECUTABLE="
set "__BYOK_BRIDGE_ARGUMENTS="
set "__BYOK_BRIDGE_CLI_ID="
set "_BYOK_BRIDGE_EXIT="
call :return %_BYOK_BRIDGE_RETURN%
exit /b %errorlevel%

:return
set "_BYOK_BRIDGE_RETURN="
exit /b %1
