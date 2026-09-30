@echo off
REM The app setup recreates its own dependencies under app/, not the firmware root.
call "%~dp0app\executables\00_First_Time_Setup.cmd"
exit /b %errorlevel%
