@echo off
setlocal
title Capstone - Open dashboards
call "%~dp0_environment.cmd"

REM Open each role in the user's default browser. Start the API and preview server
REM first, otherwise the pages will report that they are disconnected.
start "" "http://localhost:5173/"
start "" "http://localhost:5173/?preview=mobile#/mobile"
start "" "http://localhost:5173/?preview=input#/input"

echo Opened the history, mobile collector, and manual input pages.
timeout /t 3 /nobreak >nul
