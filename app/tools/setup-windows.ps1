# This script prepares the web MVP on a newly cloned Windows computer.
# It keeps large SDKs and database files inside ignored project folders so they
# never enter Git history. Run it through executables\00_First_Time_Setup.cmd.

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolsDirectory = Join-Path $projectRoot '.tools'
$localDirectory = Join-Path $projectRoot '.local'
$postgresArchive = Join-Path $toolsDirectory 'postgres-17.11-windows-x64.zip'
$postgresDirectory = Join-Path $toolsDirectory 'pgsql'
$postgresData = Join-Path $localDirectory 'pgdata'
$flutterDirectory = Join-Path $toolsDirectory 'flutter'

# These fixed versions make setup repeatable. Checksums prevent a partial or
# unexpected PostgreSQL download from being extracted and executed.
$postgresUrl = 'https://get.enterprisedb.com/postgresql/postgresql-17.11-3-windows-x64-binaries.zip'
$postgresSha256 = '4B8DB0930C38F6EF845DB919551DEDDA3B6B845AEB0927B3D79A6E8E9E4537CF'
$flutterVersion = '3.47.4'

function Write-Step([string]$message) {
  Write-Host "`n== $message ==" -ForegroundColor Cyan
}

# Locate a command after an installer changes PATH. This avoids requiring the
# student to close the setup window and open another terminal halfway through.
function Find-Command([string]$name, [string[]]$fallbacks) {
  $command = Get-Command $name -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  foreach ($candidate in $fallbacks) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return $candidate
    }
  }
  return $null
}

New-Item -ItemType Directory -Force -Path $toolsDirectory, $localDirectory | Out-Null
Set-Location -LiteralPath $projectRoot

# Flutter's Windows tooling is most reliable in a short path without spaces.
if ($projectRoot -match '\s') {
  throw "Move the repository to a short path without spaces (for example C:\Capstone), then rerun setup."
}

Write-Step 'Checking Git and Node.js'
$git = Find-Command 'git.exe' @((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'))
if (-not $git) {
  throw 'Git is required to clone this repository and install Flutter. Install Git for Windows, then rerun setup.'
}

$node = Find-Command 'node.exe' @((Join-Path $env:ProgramFiles 'nodejs\node.exe'))
if (-not $node) {
  $winget = Find-Command 'winget.exe' @()
  if (-not $winget) {
    throw 'Node.js 18 or newer is required. Install Node.js LTS, then rerun setup.'
  }
  Write-Host 'Node.js was not found. Windows Package Manager will install Node.js LTS.'
  & $winget install --id OpenJS.NodeJS.LTS --exact --source winget `
    --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) { throw 'Node.js installation failed.' }
  $node = Find-Command 'node.exe' @((Join-Path $env:ProgramFiles 'nodejs\node.exe'))
  if (-not $node) { throw 'Node.js was installed but node.exe could not be located.' }
}
$npm = Join-Path (Split-Path $node) 'npm.cmd'
if (-not (Test-Path -LiteralPath $npm)) { throw 'npm.cmd was not found beside node.exe.' }
$env:Path = "$(Split-Path $node);$env:Path"
$nodeMajor = [int](& $node -p "process.versions.node.split('.')[0]")
if ($nodeMajor -lt 18) { throw 'Node.js 18 or newer is required.' }
Write-Host "Node.js $(& $node --version)"

Write-Step 'Installing locked Node dependencies'
# npm ci uses package-lock.json exactly and removes dependency drift between PCs.
& $npm ci --prefix (Join-Path $projectRoot 'apps\api') --ignore-scripts
if ($LASTEXITCODE -ne 0) { throw 'npm dependency installation failed.' }

Write-Step 'Installing the pinned Flutter SDK'
if (-not (Test-Path -LiteralPath (Join-Path $flutterDirectory 'bin\flutter.bat'))) {
  # Flutter's official repository is used instead of committing its multi-GB SDK.
  & $git -c core.longpaths=true clone --depth 1 --branch $flutterVersion `
    https://github.com/flutter/flutter.git $flutterDirectory
  if ($LASTEXITCODE -ne 0) { throw 'Flutter download failed.' }
}
$flutter = Join-Path $flutterDirectory 'bin\flutter.bat'
$env:Path = "$(Join-Path $flutterDirectory 'bin');$env:Path"
$env:PUB_CACHE = Join-Path $toolsDirectory 'pub-cache'

Write-Step 'Installing portable PostgreSQL'
if (-not (Test-Path -LiteralPath (Join-Path $postgresDirectory 'bin\postgres.exe'))) {
  if (-not (Test-Path -LiteralPath $postgresArchive)) {
    Write-Host 'Downloading the official PostgreSQL 17.11 Windows binaries (about 326 MB)...'
    Invoke-WebRequest -Uri $postgresUrl -OutFile $postgresArchive
  }
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $postgresArchive).Hash
  if ($actualHash -ne $postgresSha256) {
    throw "PostgreSQL archive checksum failed. Delete $postgresArchive and rerun setup."
  }
  Expand-Archive -LiteralPath $postgresArchive -DestinationPath $toolsDirectory -Force
}

$initdb = Join-Path $postgresDirectory 'bin\initdb.exe'
$createdb = Join-Path $postgresDirectory 'bin\createdb.exe'
$psql = Join-Path $postgresDirectory 'bin\psql.exe'
if (-not (Test-Path -LiteralPath $initdb)) { throw 'PostgreSQL extraction did not produce initdb.exe.' }

Write-Step 'Creating or updating the local database'
if (-not (Test-Path -LiteralPath (Join-Path $postgresData 'PG_VERSION'))) {
  # Trust authentication is acceptable only because this development cluster
  # listens on loopback. Production uses credentials and TLS instead.
  & $initdb -D $postgresData -U capstone --auth=trust --encoding=UTF8 --no-locale
  if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL cluster initialization failed.' }
}

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.env'))) {
  Copy-Item -LiteralPath (Join-Path $projectRoot '.env.example') `
    -Destination (Join-Path $projectRoot '.env')
}

# The shared startup helper safely does nothing when PostgreSQL is already active.
& $node (Join-Path $projectRoot 'tools\start-postgres.js')
if ($LASTEXITCODE -ne 0) { throw 'PostgreSQL startup failed.' }

$databaseExists = & $psql -h 127.0.0.1 -p 55432 -U capstone -d postgres `
  -Atc "SELECT 1 FROM pg_database WHERE datname = 'capstone'"
if ($databaseExists -ne '1') {
  & $createdb -h 127.0.0.1 -p 55432 -U capstone capstone
  if ($LASTEXITCODE -ne 0) { throw 'Creating the capstone database failed.' }
}
& $psql -h 127.0.0.1 -p 55432 -U capstone -d capstone -v ON_ERROR_STOP=1 `
  -f (Join-Path $projectRoot 'database\schema.sql')
if ($LASTEXITCODE -ne 0) { throw 'Applying database/schema.sql failed.' }

Write-Step 'Restoring Flutter packages and building web previews'
Push-Location (Join-Path $projectRoot 'apps\monitor')
try {
  & $flutter config --no-analytics
  & $flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'Flutter package restore failed.' }
  & $flutter build web --output=build/web-viewer
  if ($LASTEXITCODE -ne 0) { throw 'Flutter web build failed.' }
} finally {
  Pop-Location
}

Write-Step 'Setup complete'
Write-Host 'The web MVP is ready. Run executables\10_Start_Web_System.cmd.'
Write-Host 'Android setup is documented separately because its SDK/emulator download is several GB.'
