@echo off
setlocal
title Capstone - First-time Android setup
call "%~dp0_environment.cmd"

REM Android is a separate setup because its SDK and emulator require roughly
REM 10 GB. The script will pause for the official Android license prompts.
echo This optional setup downloads the Android SDK, emulator, system image,
echo Java 17, and build tools. Ensure at least 15 GB of free disk space.
echo You must personally read and accept or decline the Android SDK licenses.
echo.
pause

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CAPSTONE_ROOT%\tools\setup-android-windows.ps1"
if errorlevel 1 (
  echo.
  echo Android setup did not finish. Read the error above, then retry this file.
  pause
  exit /b 1
)

echo.
echo Android setup completed. Run 05, wait for boot, and then run 06.
pause
