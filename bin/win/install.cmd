@echo off
setlocal
set "ROOT=%~dp0..\..\"
set "TARGET_DIR=%USERPROFILE%\.byok-cli-hub"
set "EXTENSION_DIR=%USERPROFILE%\.copilot\extensions\byok-cli-hub-copilot"

if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%" || goto install_error
if not exist "%EXTENSION_DIR%" mkdir "%EXTENSION_DIR%" || goto install_error
if not exist "%TARGET_DIR%\config" mkdir "%TARGET_DIR%\config" || goto install_error

copy /Y "%ROOT%config\providers.example.json" "%TARGET_DIR%\config\providers.example.json" >nul || goto install_error
if not exist "%TARGET_DIR%\config\providers.json" (
    copy /Y "%ROOT%config\providers.example.json" "%TARGET_DIR%\config\providers.json" >nul || goto install_error
)
xcopy /E /Y /I "%ROOT%manager" "%TARGET_DIR%\manager\" >nul || goto install_error
xcopy /E /Y /I "%ROOT%extension" "%EXTENSION_DIR%\" >nul || goto install_error
copy /Y "%~dp0run.cmd" "%TARGET_DIR%\run.cmd" >nul || goto install_error
copy /Y "%~dp0byok-cli-hub.cmd" "%TARGET_DIR%\byok-cli-hub.cmd" >nul || goto install_error
copy /Y "%ROOT%README.md" "%TARGET_DIR%\README.md" >nul || goto install_error
copy /Y "%ROOT%package.json" "%TARGET_DIR%\package.json" >nul || goto install_error

if /I "%BYOK_CLI_HUB_SKIP_PATH_UPDATE%"=="1" (
    echo PATH update skipped by BYOK_CLI_HUB_SKIP_PATH_UPDATE.
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET_DIR%\manager\update-user-path.ps1" -Directory "%TARGET_DIR%"
    if errorlevel 1 goto install_error
)

echo Installation complete.
echo.
echo Installed BYOK CLI Hub to:
echo   %TARGET_DIR%
echo   %EXTENSION_DIR%
echo.
echo Recommended launcher ^(local installed copy, not a remote script^):
echo   byok-cli-hub
echo.
echo Open a new terminal if the command is not available in this one.
echo Full-path fallback:
echo   call "%TARGET_DIR%\run.cmd"
echo.
echo Provider configuration:
echo   %TARGET_DIR%\config\providers.json
echo.
echo Inside Copilot, run /model_byok to switch the current model.
endlocal & exit /b 0

:install_error
echo Installation failed. Review the error above and try again.
endlocal & exit /b 1
