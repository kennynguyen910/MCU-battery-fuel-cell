@echo off
REM Shared launcher setup. Every numbered launcher calls this file first so the
REM project works even when its folder is moved to a different Windows path.

REM %~dp0 is the folder containing this script. The project root is one level up.
for %%I in ("%~dp0..") do set "CAPSTONE_ROOT=%%~fI"
cd /d "%CAPSTONE_ROOT%"

REM Prefer the project-local tools installed by 00_First_Time_Setup.cmd. Keeping
REM them local avoids requiring students to edit the system PATH by hand.
if exist "%CAPSTONE_ROOT%\.tools\flutter\bin\flutter.bat" set "PATH=%CAPSTONE_ROOT%\.tools\flutter\bin;%PATH%"
if exist "%CAPSTONE_ROOT%\.tools\java\bin\java.exe" set "JAVA_HOME=%CAPSTONE_ROOT%\.tools\java"
REM Microsoft's portable JDK archive contains one version-named child folder.
if not defined JAVA_HOME for /d %%J in ("%CAPSTONE_ROOT%\.tools\java\jdk-*") do set "JAVA_HOME=%%~fJ"
if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"
if exist "%CAPSTONE_ROOT%\.tools\android-sdk" set "ANDROID_HOME=%CAPSTONE_ROOT%\.tools\android-sdk"
if exist "%CAPSTONE_ROOT%\.tools\android-sdk" set "ANDROID_SDK_ROOT=%CAPSTONE_ROOT%\.tools\android-sdk"

REM These caches are project-local and ignored by Git. This makes cleanup and
REM transfer safer because generated files never become source code.
set "PUB_CACHE=%CAPSTONE_ROOT%\.tools\pub-cache"
set "GRADLE_USER_HOME=%CAPSTONE_ROOT%\.tools\gradle"
