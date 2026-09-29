@echo off
REM Delegate to the maintained launcher; paths work from any current directory.
call "%~dp0..\executables\05_Start_Android_Emulator.cmd"
exit /b %errorlevel%
