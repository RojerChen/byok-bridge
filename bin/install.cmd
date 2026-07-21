@echo off
set "ROOT=%~dp0..\"
set "TARGET_DIR=%USERPROFILE%\.byok-cli-hub"
set "EXTENSION_DIR=%USERPROFILE%\.copilot\extensions\byok-cli-hub-copilot"

if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
if not exist "%EXTENSION_DIR%" mkdir "%EXTENSION_DIR%"
if not exist "%TARGET_DIR%\config" mkdir "%TARGET_DIR%\config"

copy /Y "%ROOT%config\providers.example.json" "%TARGET_DIR%\config\providers.example.json" >nul
if not exist "%TARGET_DIR%\config\providers.json" (
    copy /Y "%ROOT%config\providers.example.json" "%TARGET_DIR%\config\providers.json" >nul
)
xcopy /E /Y /I "%ROOT%manager" "%TARGET_DIR%\manager\" >nul
xcopy /E /Y /I "%ROOT%extension" "%EXTENSION_DIR%\" >nul
copy /Y "%~dp0run.cmd" "%TARGET_DIR%\run.cmd" >nul
copy /Y "%ROOT%README.md" "%TARGET_DIR%\README.md" >nul
copy /Y "%ROOT%package.json" "%TARGET_DIR%\package.json" >nul

echo Installed BYOK CLI Hub to:
echo   %TARGET_DIR%
echo   %EXTENSION_DIR%
echo.
echo Next steps:
echo   1. call %TARGET_DIR%\run.cmd
echo   2. Inside Copilot run /model_byok
