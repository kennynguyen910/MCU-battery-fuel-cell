@echo off
REM Delegate to the maintained launcher; paths work from any current directory.
call "%~dp0..\executables\91_Build_Web.cmd"
exit /b %errorlevel%
