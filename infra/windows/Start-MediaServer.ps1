[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$distro = 'MediaServer'
$pidFile = 'D:\WSL\MediaServer.keeper.pid'
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'

$keeper = Start-Process -FilePath $wsl `
    -ArgumentList @('-d', $distro, '--exec', '/usr/bin/sleep', 'infinity') `
    -WindowStyle Hidden -PassThru
Set-Content -LiteralPath $pidFile -Value $keeper.Id -Encoding ascii

$deadline = (Get-Date).AddSeconds(60)
do {
    $dockerState = & $wsl -d $distro -u root -- systemctl is-active docker 2>$null
    if ($dockerState -eq 'active') { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

if ($dockerState -ne 'active') { throw 'Docker did not become active within 60 seconds' }
& $wsl -d $distro -- bash -lc 'cd /srv/media-stack && docker compose up -d'
if ($LASTEXITCODE -ne 0) { throw 'docker compose up -d failed' }

Write-Output 'MediaServer is running. Open http://localhost:8096/'
