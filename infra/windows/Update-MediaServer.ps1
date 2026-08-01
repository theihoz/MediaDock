[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$distro = 'MediaServer'
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$snapshot = 'D:\WSL\previous-images.json'

if (-not $PSCmdlet.ShouldProcess($distro, 'Pull images and recreate the media stack')) {
    return
}

& $wsl -d $distro -- bash -lc "cd /srv/media-stack && docker compose images --format json" |
    Set-Content -LiteralPath $snapshot -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Could not record previous-images snapshot' }

& $wsl -d $distro -- bash -lc 'cd /srv/media-stack && docker compose config --quiet'
if ($LASTEXITCODE -ne 0) { throw 'docker compose config failed; update aborted' }
& $wsl -d $distro -- bash -lc 'cd /srv/media-stack && docker compose pull'
if ($LASTEXITCODE -ne 0) { throw 'docker compose pull failed; existing containers remain available' }
& $wsl -d $distro -- bash -lc 'cd /srv/media-stack && docker compose up -d'
if ($LASTEXITCODE -ne 0) { throw "Recreate failed. Previous image metadata: $snapshot" }

$deadline = (Get-Date).AddSeconds(120)
do {
    $unhealthy = & $wsl -d $distro -- bash -lc "cd /srv/media-stack && docker compose ps --format json | grep -E '\"(Health|State)\":\"(unhealthy|restarting|exited)\"' || true"
    if (-not $unhealthy) {
        Write-Output "MediaServer update completed. Previous image metadata: $snapshot"
        return
    }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

throw "Update finished with unhealthy services. Previous image metadata: $snapshot"
