@echo off
REM The app setup recreates its own dependencies under mobile_app/, not the firmware root.
call "%~dp0mobile_app\executables\00_First_Time_Setup.cmd"
exit /b %errorlevel%
