$ErrorActionPreference = 'Stop'
$displayRoot = Split-Path -Parent $PSScriptRoot
$displayRepo = Split-Path -Parent $displayRoot
$displayBuild = Join-Path $displayRoot 'build/lcd-format-tests'
New-Item -ItemType Directory -Force -Path $displayBuild | Out-Null
Push-Location -LiteralPath $displayRepo
try {
    $displayArgs = @('-std=c++17', '-Wall', '-Wextra', '-Werror', 'firmware/main/lcd_display_format.cpp', 'firmware/tools/test_lcd_display.cpp', '-Ifirmware/main', '-o', 'firmware/build/lcd-format-tests/test_lcd_display')
    if (Get-Command g++ -ErrorAction SilentlyContinue) {
        $displayArgs[-1] += '.exe'
        & g++ @displayArgs
        if ($LASTEXITCODE -ne 0) { throw 'LCD formatter tests compile failed' }
        & (Join-Path $displayBuild 'test_lcd_display.exe')
    } else {
        & wsl.exe -d Ubuntu -- g++ @displayArgs
        if ($LASTEXITCODE -ne 0) { throw 'LCD formatter tests compile failed; inspect compiler output' }
        & wsl.exe -d Ubuntu -- ./firmware/build/lcd-format-tests/test_lcd_display
    }
    if ($LASTEXITCODE -ne 0) { throw "LCD formatting test failed: case $LASTEXITCODE" }
    Write-Output 'PASS: LCD formatting, validity, provenance, status mapping and page rotation'
} finally {
    Pop-Location
}
