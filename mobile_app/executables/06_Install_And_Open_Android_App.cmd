@echo off
setlocal
title Capstone - Install Android app
call "%~dp0_environment.cmd"

REM This launcher expects 05_Start_Android_Emulator.cmd to be running already.
set "ADB=%CAPSTONE_ROOT%\.tools\android-sdk\platform-tools\adb.exe"
set "APK=%CAPSTONE_ROOT%\build\app\outputs\flutter-apk\app-debug.apk"
if not exist "%ADB%" (
  echo Android platform tools were not found. Run 00_First_Time_Setup.cmd first.
  pause
  exit /b 1
)
if not exist "%APK%" (
  echo The Android APK is missing. Run 92_Build_Android.cmd first.
  pause
  exit /b 1
)

REM Fail quickly when no Android device is connected instead of waiting forever.
"%ADB%" get-state >nul 2>&1
if errorlevel 1 (
  echo No Android device is ready. Start the emulator and wait for its home screen.
  pause
  exit /b 1
)

REM -r replaces an older debug build while preserving its local application data.
"%ADB%" install -r "%APK%"
if errorlevel 1 (
  echo APK installation failed.
  pause
  exit /b 1
)
"%ADB%" shell am force-stop com.example.capstone_monitor
"%ADB%" shell am start -n com.example.capstone_monitor/com.example.capstone_monitor.MainActivity
echo.
echo The Capstone collector is open in Android.
pause
