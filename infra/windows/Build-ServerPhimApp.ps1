[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$appRoot = Join-Path $repoRoot 'app\server_phim'
$logPath = Join-Path $repoRoot 'flutter-build.log'

Push-Location $appRoot
try {
    & flutter.bat build windows --release *>&1 | Tee-Object -FilePath $logPath
    if ($LASTEXITCODE -ne 0) { throw "Flutter build failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
