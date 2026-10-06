# Optional Android toolchain setup for a Windows development computer.
# The user runs this after the smaller web setup because Android downloads are
# several gigabytes and require accepting Google's SDK license agreements.

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolsDirectory = Join-Path $projectRoot '.tools'
$javaDirectory = Join-Path $toolsDirectory 'java'
$androidDirectory = Join-Path $toolsDirectory 'android-sdk'
$javaArchive = Join-Path $toolsDirectory 'microsoft-jdk-17.0.20.1.zip'
$androidArchive = Join-Path $toolsDirectory 'android-command-line-tools-22.zip'

# Fixed official downloads plus checksums make the setup repeatable and detect
# interrupted downloads before any executable is used.
$javaUrl = 'https://aka.ms/download-jdk/microsoft-jdk-17.0.20.1-windows-x64.zip'
$javaSha256 = '3D9006956FC8AF5601CD24FFC4F468BEF48279C7EBD8171B9BDF90D0AABFBF1F'
$androidUrl = 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip'
$androidSha256 = '90AE805D20434428BFFCB699C290860F19BB5F66A67E6B330067E3DE801FB04A'

function Write-Step([string]$message) {
  Write-Host "`n== $message ==" -ForegroundColor Cyan
}

function Get-VerifiedArchive([string]$url, [string]$path, [string]$expectedHash) {
  if (-not (Test-Path -LiteralPath $path)) {
    Invoke-WebRequest -Uri $url -OutFile $path
  }
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
  if ($actualHash -ne $expectedHash) {
    throw "Checksum failed for $path. Delete that file and rerun Android setup."
  }
}

New-Item -ItemType Directory -Force -Path $toolsDirectory | Out-Null

Write-Step 'Installing portable Java 17'
$java = Get-ChildItem -LiteralPath $javaDirectory -Filter java.exe -File -Recurse `
  -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $java) {
  Get-VerifiedArchive $javaUrl $javaArchive $javaSha256
  New-Item -ItemType Directory -Force -Path $javaDirectory | Out-Null
  Expand-Archive -LiteralPath $javaArchive -DestinationPath $javaDirectory -Force
  $java = Get-ChildItem -LiteralPath $javaDirectory -Filter java.exe -File -Recurse |
    Select-Object -First 1
}
if (-not $java) { throw 'Java extraction did not produce java.exe.' }
$env:JAVA_HOME = Split-Path (Split-Path $java.FullName)
$env:Path = "$(Join-Path $env:JAVA_HOME 'bin');$env:Path"
# Java prints its version banner to stderr even when it succeeds. Windows
# PowerShell can turn that banner into a terminating NativeCommandError while
# ErrorActionPreference is Stop, so capture the banner without changing the
# script's strict error handling.
$javaStartInfo = New-Object System.Diagnostics.ProcessStartInfo
$javaStartInfo.FileName = $java.FullName
$javaStartInfo.Arguments = '-version'
$javaStartInfo.UseShellExecute = $false
$javaStartInfo.RedirectStandardError = $true
$javaProcess = [System.Diagnostics.Process]::Start($javaStartInfo)
$javaVersion = $javaProcess.StandardError.ReadLine()
$javaProcess.WaitForExit()
if ($javaProcess.ExitCode -ne 0) { throw 'Java failed its version check.' }
Write-Host $javaVersion

Write-Step 'Installing Android command-line tools'
$sdkManager = Join-Path $androidDirectory 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path -LiteralPath $sdkManager)) {
  Get-VerifiedArchive $androidUrl $androidArchive $androidSha256
  $temporaryDirectory = Join-Path $toolsDirectory 'android-command-line-extract'
  if (Test-Path -LiteralPath $temporaryDirectory) {
    throw "Temporary folder already exists: $temporaryDirectory. Remove it and rerun setup."
  }
  Expand-Archive -LiteralPath $androidArchive -DestinationPath $temporaryDirectory
  New-Item -ItemType Directory -Force -Path (Join-Path $androidDirectory 'cmdline-tools') | Out-Null
  Move-Item -LiteralPath (Join-Path $temporaryDirectory 'cmdline-tools') `
    -Destination (Join-Path $androidDirectory 'cmdline-tools\latest')
}
if (-not (Test-Path -LiteralPath $sdkManager)) {
  throw 'Android extraction did not produce sdkmanager.bat.'
}
$env:ANDROID_HOME = $androidDirectory
$env:ANDROID_SDK_ROOT = $androidDirectory

Write-Step 'Reviewing Android SDK licenses'
Write-Host 'The official license prompts below require your own response.'
& $sdkManager --sdk_root=$androidDirectory --licenses
if ($LASTEXITCODE -ne 0) { throw 'Android SDK licenses were not completed.' }

Write-Step 'Downloading Android build and emulator packages'
$packages = @(
  'platform-tools',
  'emulator',
  'platforms;android-36',
  'platforms;android-37.0', # Required by the current BLE/permission plugins.
  'build-tools;36.0.0',
  'system-images;android-36;google_apis;x86_64',
  'cmake;3.22.1',
  'ndk;28.2.13676358'
)
& $sdkManager --sdk_root=$androidDirectory $packages
if ($LASTEXITCODE -ne 0) { throw 'One or more Android SDK packages failed to install.' }

Write-Step 'Creating the Capstone_Test emulator'
$avdManager = Join-Path $androidDirectory 'cmdline-tools\latest\bin\avdmanager.bat'
$existingAvds = & $avdManager list avd
if ($existingAvds -notmatch 'Name:\s+Capstone_Test') {
  # "no" chooses the standard Pixel 6 hardware profile without custom editing.
  'no' | & $avdManager create avd --force --name Capstone_Test --device pixel_6 `
    --package 'system-images;android-36;google_apis;x86_64'
  if ($LASTEXITCODE -ne 0) { throw 'Creating the Android emulator failed.' }
}

Write-Step 'Connecting Flutter to Android and building the debug APK'
$flutter = Join-Path $toolsDirectory 'flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) {
  throw 'Flutter is missing. Run executables\00_First_Time_Setup.cmd first.'
}
$env:PUB_CACHE = Join-Path $toolsDirectory 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $toolsDirectory 'gradle'
& $flutter config --android-sdk $androidDirectory
Push-Location (Join-Path $projectRoot '.')
try {
  & $flutter build apk --debug -t lib/main_mobile.dart `
    --dart-define=API_URL=http://10.0.2.2:3001
  if ($LASTEXITCODE -ne 0) { throw 'Android APK build failed.' }
} finally {
  Pop-Location
}

Write-Step 'Android setup complete'
Write-Host 'Run executables\05_Start_Android_Emulator.cmd, wait for boot, then run 06.'
