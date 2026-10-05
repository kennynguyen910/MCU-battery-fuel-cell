@echo off
setlocal
title Capstone - Build Android APK
call "%~dp0_environment.cmd"

REM Build a debug APK whose API address maps from the Android emulator to this PC.
call "%CAPSTONE_ROOT%\dev.cmd" android
if errorlevel 1 (
  echo.
  echo Android build failed. Read the error above.
  pause
  exit /b 1
)

echo.
echo APK created at:
echo %CAPSTONE_ROOT%\apps\monitor\build\app\outputs\flutter-apk\app-debug.apk
pause
