@echo off
setlocal
title Capstone - Configure AWS Database
call "%~dp0_environment.cmd"

REM This helper checks the network, requests the password without displaying it,
REM installs the schema, and writes only to the Git-ignored local .env file.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CAPSTONE_ROOT%\tools\configure-aws-database.ps1"

REM Keep the result visible so a student can read any AWS guidance or error.
echo.
pause
