@echo off
setlocal
title Capstone - Express API
call "%~dp0_environment.cmd"

REM Keep this window open. The Flutter apps send requests to this Express server,
REM and the server validates data before reading or writing PostgreSQL.
echo Starting the Express API on http://localhost:3001 ...
node "%CAPSTONE_ROOT%\apps\api\src\server.js"

REM Reaching this line means the server stopped or could not start.
echo.
echo The API has stopped. Review any error shown above.
pause
