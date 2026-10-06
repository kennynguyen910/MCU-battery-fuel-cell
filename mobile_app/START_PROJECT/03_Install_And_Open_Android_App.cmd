@echo off
REM Delegate to the maintained launcher; paths work from any current directory.
call "%~dp0..\executables\06_Install_And_Open_Android_App.cmd"
exit /b %errorlevel%
