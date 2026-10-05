@echo off
setlocal
title Capstone - Start everything
call "%~dp0_environment.cmd"

REM Start the web system first because the Android collector needs its API.
start "Capstone Web System" cmd.exe /c ""%~dp010_Start_Web_System.cmd""
timeout /t 4 /nobreak >nul

REM Start Android separately because the emulator is resource-intensive and
REM takes longer to boot than the local web services.
start "Capstone Android Emulator" cmd.exe /c ""%~dp005_Start_Android_Emulator.cmd""

echo.
echo Web components are starting now.
echo After Android reaches its home screen, run 06_Install_And_Open_Android_App.cmd.
pause
