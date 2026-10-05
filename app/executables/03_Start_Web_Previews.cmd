@echo off
setlocal
title Capstone - Flutter web previews
call "%~dp0_environment.cmd"

REM Keep this window open. This small Express process serves the already-built
REM Flutter web files; it does not contain application or database logic.
if not exist "%CAPSTONE_ROOT%\apps\monitor\build\web-viewer\index.html" (
  echo The Flutter web build is missing.
  echo Run 91_Build_Web.cmd, then try this launcher again.
  pause
  exit /b 1
)

echo Starting Flutter previews on http://localhost:5173 ...
node "%CAPSTONE_ROOT%\apps\api\src\preview.js"

REM Reaching this line means the preview server stopped or could not start.
echo.
echo The preview server has stopped. Review any error shown above.
pause
