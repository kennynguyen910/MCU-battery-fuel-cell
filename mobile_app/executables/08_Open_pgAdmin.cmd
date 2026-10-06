@echo off
setlocal
call "%~dp0_environment.cmd"
REM The portable PostgreSQL DLLs must precede installations from other PCs.
set "PATH=%CAPSTONE_ROOT%\.tools\pgsql\bin;%CAPSTONE_ROOT%\.tools\pgsql\pgAdmin 4\runtime;%PATH%"
start "" "%CAPSTONE_ROOT%\.tools\pgsql\pgAdmin 4\runtime\pgAdmin4.exe"
