@echo off
REM Delegate to the maintained launcher; paths work from any current directory.
call "%~dp0..\executables\07_Prove_AWS_Postgres.cmd"
exit /b %errorlevel%
