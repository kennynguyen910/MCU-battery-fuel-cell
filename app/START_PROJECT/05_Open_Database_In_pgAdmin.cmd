@echo off
REM Delegate to the maintained launcher; paths work from any current directory.
call "%~dp0..\executables\08_Open_pgAdmin.cmd"
exit /b %errorlevel%
