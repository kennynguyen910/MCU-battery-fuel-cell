$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
$flutter = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
if (-not (Test-Path $flutter)) { throw 'Run executables\00_First_Time_Setup.cmd first.' }
$env:LOCALAPPDATA = Join-Path $projectRoot '.local\appdata'
$env:PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
$output = Join-Path $projectRoot 'apps\monitor\build\web-viewer\main.dart.js'
$sources = Get-ChildItem (Join-Path $projectRoot 'apps\monitor\lib'), (Join-Path $projectRoot 'apps\monitor\web') -Recurse -File
$newest = ($sources | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
if (-not (Test-Path $output) -or (Get-Item $output).LastWriteTime -lt $newest) {
    Write-Host 'Building the current demo screens...'
    Push-Location (Join-Path $projectRoot 'apps\monitor')
    try {
        & $flutter build web --no-pub --output=build/web-viewer
        if ($LASTEXITCODE -ne 0) { throw 'Web build failed. See the output above.' }
    } finally { Pop-Location }
}
& node (Join-Path $projectRoot 'tools\demo.js') --open
if ($LASTEXITCODE -ne 0) { throw 'Demo stopped with an error. Check whether port 3301 or 15005 is already in use.' }
