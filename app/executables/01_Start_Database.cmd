@echo off
setlocal
title Capstone - PostgreSQL
call "%~dp0_environment.cmd"

REM PostgreSQL stores every uploaded session and measurement. This command starts
REM the local database only; it does not start the API or any user interface.
node "%CAPSTONE_ROOT%\tools\start-postgres.js"
if errorlevel 1 (
  echo.
  echo Database startup failed. Run 00_First_Time_Setup.cmd first.
  pause
  exit /b 1
)

echo.
echo Database is ready. This window may now be closed.
pause
