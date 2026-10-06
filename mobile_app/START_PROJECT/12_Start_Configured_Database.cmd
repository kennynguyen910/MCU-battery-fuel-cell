@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File tools\prepare-app.ps1 -ConfiguredDatabase
if errorlevel 1 pause
