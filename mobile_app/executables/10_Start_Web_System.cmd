@echo off
REM Start the maintained normal app launcher, with persistent local storage.
call "%~dp0..\START_PROJECT\01_Start_WebApp.cmd"
exit /b %errorlevel%
