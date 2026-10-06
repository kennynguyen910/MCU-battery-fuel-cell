@echo off
setlocal
call "%~dp0_environment.cmd"
REM Start missing services and open the device-input page.
node "%CAPSTONE_ROOT%\tools\open-web.js" --input
if errorlevel 1 (
  pause
  exit /b 1
)
