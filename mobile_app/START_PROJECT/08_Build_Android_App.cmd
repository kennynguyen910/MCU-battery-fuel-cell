@echo off
REM Delegate to the maintained launcher; paths work from any current directory.
call "%~dp0..\executables\92_Build_Android.cmd"
exit /b %errorlevel%
