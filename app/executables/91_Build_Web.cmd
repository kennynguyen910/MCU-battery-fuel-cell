@echo off
setlocal
title Capstone - Build Flutter web
call "%~dp0_environment.cmd"

REM Compile the shared Dart source into the static web files served on port 5173.
call "%CAPSTONE_ROOT%\dev.cmd" build
if errorlevel 1 (
  echo.
  echo Flutter web build failed. Read the error above.
  pause
  exit /b 1
)

echo.
echo Web build completed successfully.
REM Reuse running services, or start them before opening the website.
node "%CAPSTONE_ROOT%\tools\open-web.js"
if errorlevel 1 (
  echo Build succeeded, but the web app could not be opened. Read the error above.
  pause
  exit /b 1
)
pause
