@echo off
setlocal
title Capstone - Stop PostgreSQL
call "%~dp0_environment.cmd"

REM Stop only this project's local PostgreSQL cluster. Saved database files stay
REM under .local\pgdata and will be reused at the next startup.
set "PG_CTL=%CAPSTONE_ROOT%\.tools\pgsql\bin\pg_ctl.exe"
if not exist "%PG_CTL%" (
  echo Local PostgreSQL was not found.
  pause
  exit /b 1
)
"%PG_CTL%" -D "%CAPSTONE_ROOT%\.local\pgdata" stop
echo.
echo PostgreSQL stopped. Saved measurements were not deleted.
pause
