@echo off
REM App and firmware share a repository but remain separate runtime programs.
call "%~dp0mobile_app\Start_Capstone.cmd"
exit /b %errorlevel%
