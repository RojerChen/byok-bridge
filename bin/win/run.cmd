@echo off
rem The public CMD entry point applies the resolved environment to this caller
rem console. This intentionally keeps provider/model/key values available for
rem the next invocation, matching the original 0.0.1 Windows contract.
set "_BYOK_BRIDGE_PSEXE=pwsh"
where pwsh >nul 2>nul
if errorlevel 1 set "_BYOK_BRIDGE_PSEXE=powershell"

set "_BYOK_BRIDGE_ROOT=%~dp0"
if not exist "%_BYOK_BRIDGE_ROOT%manager\start-byok-bridge.ps1" set "_BYOK_BRIDGE_ROOT=%~dp0..\..\"
set "_BYOK_BRIDGE_ENV_FILE=%TEMP%\byok-bridge-env-%RANDOM%-%RANDOM%.cmd"
set "__BYOK_BRIDGE_ACTION="
set "__BYOK_BRIDGE_EXECUTABLE="
set "__BYOK_BRIDGE_ARGUMENTS="
set "__BYOK_BRIDGE_CLI_ID="

%_BYOK_BRIDGE_PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%_BYOK_BRIDGE_ROOT%manager\start-byok-bridge.ps1" -EnvFile "%_BYOK_BRIDGE_ENV_FILE%" %*
set "_BYOK_BRIDGE_MANAGER_EXIT=%errorlevel%"
if not "%_BYOK_BRIDGE_MANAGER_EXIT%"=="0" goto :manager_failed
if not exist "%_BYOK_BRIDGE_ENV_FILE%" goto :missing_plan

call "%_BYOK_BRIDGE_ENV_FILE%"
set "_BYOK_BRIDGE_PLAN_EXIT=%errorlevel%"
del /q "%_BYOK_BRIDGE_ENV_FILE%" >nul 2>nul
set "_BYOK_BRIDGE_ENV_FILE="
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
if exist "%_BYOK_BRIDGE_ENV_FILE%" del /q "%_BYOK_BRIDGE_ENV_FILE%" >nul 2>nul
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
set "_BYOK_BRIDGE_PSEXE="
set "_BYOK_BRIDGE_ROOT="
set "_BYOK_BRIDGE_ENV_FILE="
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
