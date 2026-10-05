# Configure this computer to use the team's AWS RDS PostgreSQL database.
# The password is requested privately and is never accepted as a command-line
# argument, where it could appear in shell history or a process listing.

$ErrorActionPreference = 'Stop'

# Resolve every path from this script so the repository can be moved safely.
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$localAwsDirectory = Join-Path $projectRoot '.local\aws'
$certificatePath = Join-Path $localAwsDirectory 'global-bundle.pem'
# PostgreSQL connection strings treat backslashes as escape characters. Forward
# slashes work on Windows and keep the certificate filename intact for psql.
$psqlCertificatePath = $certificatePath.Replace('\', '/')
$psqlPath = Join-Path $projectRoot '.tools\pgsql\bin\psql.exe'
$schemaPath = Join-Path $projectRoot 'database\schema.sql'
$environmentPath = Join-Path $projectRoot '.env'

# These values are identifiers, not secrets. Only the password stays private.
$databaseHost = 'capstone-postgres.cj0kowcoegeo.us-east-2.rds.amazonaws.com'
$databasePort = 5432
$databaseName = 'capstone'
$databaseUser = 'capstone_admin'

Write-Host 'Checking whether this computer can reach AWS PostgreSQL...'
$connectionTest = Test-NetConnection -ComputerName $databaseHost -Port $databasePort -WarningAction SilentlyContinue
if (-not $connectionTest.TcpTestSucceeded) {
  Write-Host ''
  Write-Host 'AWS PostgreSQL is not reachable from this network.' -ForegroundColor Red
  Write-Host 'In AWS, open the capstone-rds-local security group and update its'
  Write-Host 'PostgreSQL inbound rule to use My IP, then run this launcher again.'
  exit 1
}

# The first-time project setup installs a portable psql client in .tools.
if (-not (Test-Path -LiteralPath $psqlPath)) {
  Write-Host 'The PostgreSQL client is missing.' -ForegroundColor Red
  Write-Host 'Run executables\00_First_Time_Setup.cmd, then try again.'
  exit 1
}

# AWS publishes this certificate bundle for verifying RDS server identities.
New-Item -ItemType Directory -Path $localAwsDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $certificatePath)) {
  Write-Host 'Downloading the official AWS RDS certificate bundle...'
  Invoke-WebRequest `
    -Uri 'https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem' `
    -OutFile $certificatePath
}

Write-Host ''
Write-Host 'Enter the master password you created in AWS.'
$securePassword = Read-Host 'Database password' -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)

try {
  # psql and Node need the plain password briefly. It remains inside this process,
  # and Uri escaping prevents punctuation from breaking DATABASE_URL parsing.
  $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
  $encodedPassword = [Uri]::EscapeDataString($plainPassword)

  Write-Host 'Applying the project database schema over verified TLS...'
  $env:PGPASSWORD = $plainPassword
  & $psqlPath `
    "host=$databaseHost port=$databasePort dbname=$databaseName user=$databaseUser sslmode=verify-full sslrootcert=$psqlCertificatePath" `
    -v ON_ERROR_STOP=1 `
    -f $schemaPath
  if ($LASTEXITCODE -ne 0) {
    throw 'PostgreSQL rejected the connection or schema.'
  }

  # Preserve unrelated local settings while replacing database-specific values.
  $existingLines = if (Test-Path -LiteralPath $environmentPath) {
    Get-Content -LiteralPath $environmentPath | Where-Object {
      $_ -notmatch '^(PORT|DATABASE_URL|DATABASE_SSL_CA)='
    }
  } else {
    @()
  }
  $databaseUrl = "postgresql://${databaseUser}:${encodedPassword}@${databaseHost}:${databasePort}/${databaseName}"
  $newLines = @($existingLines) + @(
    'PORT=3001',
    "DATABASE_URL=$databaseUrl",
    'DATABASE_SSL_CA=.local/aws/global-bundle.pem'
  )
  Set-Content -LiteralPath $environmentPath -Value $newLines -Encoding UTF8

  Write-Host ''
  Write-Host 'AWS PostgreSQL is configured and the schema is installed.' -ForegroundColor Green
  Write-Host 'Next, run executables\02_Start_API.cmd.'
} finally {
  # Clear temporary password copies even when psql reports an error.
  Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
  $plainPassword = $null
  $securePassword.Dispose()
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
}
