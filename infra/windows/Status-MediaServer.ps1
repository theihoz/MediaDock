[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$distro = 'MediaServer'
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'

& $wsl --list --verbose
& $wsl -d $distro -- bash -lc 'cd /srv/media-stack && docker compose ps'
