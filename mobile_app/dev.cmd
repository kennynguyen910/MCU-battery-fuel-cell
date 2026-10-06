@echo off
setlocal
REM Developer command dispatcher. The numbered files in executables\ are easier
REM for demonstrations; this compact command is convenient while writing code.
cd /d "%~dp0"

REM Prefer SDKs and caches stored inside the project. These folders are ignored
REM by Git because they are large, generated, and specific to one computer.
set "PATH=%CD%\.tools\flutter\bin;%PATH%"
set "PUB_CACHE=%CD%\.tools\pub-cache"
set "GRADLE_USER_HOME=%CD%\.tools\gradle"
set "ANDROID_HOME=%CD%\.tools\android-sdk"
if /i "%~1"=="build" goto build
if /i "%~1"=="android" goto android
if /i "%~1"=="test" goto test
if /i "%~1"=="app" goto app

REM With no argument, start PostgreSQL plus both long-running Node processes.
node tools/dev.js
exit /b %errorlevel%
:build
REM Recreate the Flutter web files used by the preview server.
cd .
call flutter pub get
if errorlevel 1 exit /b 1
call flutter build web --output=build/web-viewer
exit /b %errorlevel%
:android
REM 10.0.2.2 is the Android emulator's special address for the host PC.
cd .
call flutter build apk --debug -t lib/main_mobile.dart --dart-define=API_URL=http://10.0.2.2:3001
exit /b %errorlevel%
:app
REM Port 5174 is reserved for Flutter's hot-reload development server.
cd .
call flutter run -d web-server --web-port 5174 -t lib/main_mobile.dart
exit /b %errorlevel%
:test
REM Integration tests need the real local database; starting it is idempotent.
node tools/start-postgres.js
if errorlevel 1 exit /b 1
REM Stop immediately after the first failing boundary so its error remains clear.
node tools/test-api.js
if errorlevel 1 exit /b 1
cd .
call flutter test
if errorlevel 1 exit /b 1
call flutter analyze
exit /b %errorlevel%
