@echo off
setlocal
title Capstone - Automated tests
call "%~dp0_environment.cmd"

REM This runs API unit tests, the real PostgreSQL flow test, Flutter widget/unit
REM tests, and static analysis. It does not erase existing database records.
call "%CAPSTONE_ROOT%\dev.cmd" test
if errorlevel 1 (
  echo.
  echo One or more checks failed. Read the first failure above.
  pause
  exit /b 1
)

echo.
echo All automated checks passed.
pause
