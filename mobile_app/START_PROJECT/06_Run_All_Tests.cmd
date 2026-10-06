@echo off
REM Delegate to the maintained launcher; paths work from any current directory.
call "%~dp0..\executables\90_Run_All_Tests.cmd"
exit /b %errorlevel%
