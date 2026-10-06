param([switch]$ConfiguredDatabase)
$ErrorActionPreference = 'Stop'
$username = Read-Host 'New username (case-sensitive)'
$secret = Read-Host 'Password (at least 12 characters)' -AsSecureString
$confirmation = Read-Host 'Confirm password' -AsSecureString
$first = [IntPtr]::Zero
$second = [IntPtr]::Zero
try {
    $first = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    $second = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($first)
    if ($password -cne [Runtime.InteropServices.Marshal]::PtrToStringBSTR($second)) {
        throw 'Passwords do not match. No account was created.'
    }
    $arguments = @()
    if ($ConfiguredDatabase) { $arguments += '--configured-database' }
    $OutputEncoding = New-Object System.Text.UTF8Encoding
    @{ username = $username; password = $password } | ConvertTo-Json -Compress |
        & node (Join-Path $PSScriptRoot 'add-user.js') @arguments
    if ($LASTEXITCODE -ne 0) { throw 'User creation failed.' }
} finally {
    if ($first -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($first) }
    if ($second -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($second) }
    $password = $null
    $secret.Dispose()
    $confirmation.Dispose()
}
