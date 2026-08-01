$ErrorActionPreference = 'Stop'

$infraRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $infraRoot 'config\media-stack.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Manifest missing: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$expectedServices = @(
    'jellyfin', 'seerr', 'radarr', 'sonarr', 'lidarr', 'prowlarr', 'bazarr',
    'qbittorrent', 'sabnzbd', 'autobrr', 'flaresolverr', 'cleanuparr', 'wizarr'
)

if ($manifest.distroName -ne 'MediaServer') { throw 'Unexpected distroName' }
if ($manifest.distroPath -ne 'D:\WSL\MediaServer') { throw 'Unexpected distroPath' }
if ($manifest.mediaRoot -ne 'D:\Media') { throw 'Unexpected mediaRoot' }
if (@($manifest.services).Count -ne 13) { throw 'Expected exactly 13 services' }
if (@($manifest.services | Sort-Object -Unique).Count -ne 13) { throw 'Service names must be unique' }
if (Compare-Object ($expectedServices | Sort-Object) ($manifest.services | Sort-Object)) {
    throw 'Service list does not match the approved stack'
}
if ([int]$manifest.ports.qbittorrent.host -ne 8081) { throw 'qBittorrent host port must be 8081' }
if ($manifest.publishedLanPorts -contains 8191) { throw 'FlareSolverr must remain internal-only' }
if (@($manifest.publishedLanPorts | Sort-Object -Unique).Count -ne @($manifest.publishedLanPorts).Count) {
    throw 'Published LAN ports must be unique'
}

$productionRoots = @('windows', 'linux') | ForEach-Object { Join-Path $infraRoot $_ }
$forbidden = 'wsl' + '\s+--unregister'
foreach ($root in $productionRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $matches = Get-ChildItem -LiteralPath $root -File -Recurse |
        Select-String -Pattern $forbidden -CaseSensitive:$false
    if ($matches) { throw "Destructive WSL unregister command found under $root" }
}

$installerPath = Join-Path $infraRoot 'windows\Install-MediaServer.ps1'
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "Installer missing: $installerPath"
}
$installer = Get-Content -LiteralPath $installerPath -Raw
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Installer has PowerShell parse errors: $($parseErrors.Message -join '; ')"
}
$requiredInstallerPatterns = @(
    '80GB',
    '--list\s+--online',
    '--install\s+Ubuntu-24\.04',
    '--name\s+MediaServer',
    '--location',
    '--no-launch',
    'DefaultDistribution',
    'BasePath',
    'SkipDistroInstall',
    'PreflightOnly'
)
foreach ($pattern in $requiredInstallerPatterns) {
    if ($installer -notmatch $pattern) { throw "Installer contract missing pattern: $pattern" }
}
if ($installer -notmatch 'PSChildName\.Trim\(''\{\}''\)\s+-eq\s+\$defaultId\.Trim\(''\{\}''\)') {
    throw 'Installer must compare normalized WSL registry GUIDs'
}
if (-not $installer.Contains(".Replace('\', '/')") -or -not $installer.Contains("'/mnt/'")) {
    throw 'Installer must convert its script path to /mnt/<drive> without wslpath'
}
$initializerPath = Join-Path $infraRoot 'linux\initialize-wsl.sh'
if (-not (Test-Path -LiteralPath $initializerPath)) { throw "WSL initializer missing: $initializerPath" }
$initializer = Get-Content -LiteralPath $initializerPath -Raw
foreach ($pattern in @('systemd=true', 'default=media', 'metadata,uid=1000,gid=1000', 'useradd')) {
    if ($initializer -notmatch [regex]::Escape($pattern)) {
        throw "WSL initializer contract missing: $pattern"
    }
}
if ($initializer -match 'NOPASSWD' -or $initializer -match 'groups\s+sudo') {
    throw 'The media user must not receive broad sudo privileges'
}

Write-Output 'PASS static media-stack contract'
