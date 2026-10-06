@echo off
setlocal
title Capstone - Android emulator
call "%~dp0_environment.cmd"

REM The emulator is optional for a web-only demo. It shows the same collector
REM code inside a real Android environment.
set "EMULATOR=%CAPSTONE_ROOT%\.tools\android-sdk\emulator\emulator.exe"
if not exist "%EMULATOR%" (
  echo Android emulator not found. Run 00_First_Time_Setup.cmd first.
  pause
  exit /b 1
)

REM Capstone_Test is the development device created during setup.
node "%CAPSTONE_ROOT%\tools\start-android.js"
if errorlevel 1 (
  echo.
  echo Emulator startup failed. Read the actual error above.
  pause
  exit /b 1
)
