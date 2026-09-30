@echo off
REM App and firmware share a repository but remain separate runtime programs.
call "%~dp0app\Start_Capstone.cmd"
exit /b %errorlevel%
