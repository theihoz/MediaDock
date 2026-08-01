[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$appRoot = Join-Path $repoRoot 'app\server_phim'

Push-Location $appRoot
try {
    & flutter.bat analyze
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analyze failed; installed app was not changed' }
    & flutter.bat test
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed; installed app was not changed' }
    & flutter.bat build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed; installed app was not changed' }
} finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot 'Install-ServerPhimApp.ps1')
if ($LASTEXITCODE -ne 0) { throw 'App install failed and was rolled back' }
