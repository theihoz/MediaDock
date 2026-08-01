[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$distro = 'MediaServer'
$pidFile = 'D:\WSL\MediaServer.keeper.pid'
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'

& $wsl -d $distro -- bash -lc 'cd /srv/media-stack && docker compose down'
& $wsl --terminate MediaServer

if (Test-Path -LiteralPath $pidFile) {
    $keeperId = [int](Get-Content -LiteralPath $pidFile -Raw)
    Stop-Process -Id $keeperId -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pidFile -Force
}

Write-Output 'MediaServer has stopped.'
