param([switch]$NoOpen, [switch]$ConfiguredDatabase)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Set-Location $projectRoot
$flutter = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
if (-not (Test-Path $flutter)) { throw 'Run executables\00_First_Time_Setup.cmd first.' }
$env:LOCALAPPDATA = Join-Path $projectRoot '.local\appdata'
$env:PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
$output = Join-Path $projectRoot 'build\web-viewer\main.dart.js'
$sources = Get-ChildItem (Join-Path $projectRoot 'lib'), (Join-Path $projectRoot 'web') -Recurse -File
$newest = ($sources | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
if (-not (Test-Path $output) -or (Get-Item $output).LastWriteTime -lt $newest) {
    Write-Host 'Updating the app screens...'
    Push-Location (Join-Path $projectRoot '.')
    try {
        & $flutter build web --no-pub --output=build/web-viewer
        if ($LASTEXITCODE -ne 0) { throw 'Web build failed. See the output above.' }
    } finally { Pop-Location }
}
$launchArgs = @()
if ($NoOpen) { $launchArgs += '--no-open' }
if ($ConfiguredDatabase) { $launchArgs += '--configured-database' }
& node (Join-Path $projectRoot 'tools\start-app.js') @launchArgs
if ($LASTEXITCODE -ne 0) { throw 'The app could not start. See the specific error above.' }
