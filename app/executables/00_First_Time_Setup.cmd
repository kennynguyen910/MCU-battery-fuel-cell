@echo off
setlocal
title Capstone - First-time setup
call "%~dp0_environment.cmd"

REM This launcher prepares a newly cloned repository. It is safe to run again;
REM the PowerShell setup script skips tools that are already present.
echo Preparing this computer for the Capstone MVP...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CAPSTONE_ROOT%\tools\setup-windows.ps1"
if errorlevel 1 (
  echo.
  echo Setup did not finish. Read the error above, then run this file again.
  pause
  exit /b 1
)

echo.
echo Setup completed. Next, run 10_Start_Web_System.cmd.
pause
