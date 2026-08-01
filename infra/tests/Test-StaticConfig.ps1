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
if ([int]$manifest.ports.qbittorrent.container -ne 8081) { throw 'qBittorrent container WebUI port must match host port for CSRF validation' }
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
$attributesPath = Join-Path (Split-Path -Parent $infraRoot) '.gitattributes'
if (-not (Test-Path -LiteralPath $attributesPath)) { throw '.gitattributes is required for Linux scripts' }
$attributes = Get-Content -LiteralPath $attributesPath -Raw
if ($attributes -notmatch '\*\.sh\s+text\s+eol=lf') { throw 'Shell scripts must use LF endings' }
$hostVerifier = Join-Path $infraRoot 'linux\verify-host.sh'
if (-not (Test-Path -LiteralPath $hostVerifier)) { throw "Host verifier missing: $hostVerifier" }
$hostBootstrap = Join-Path $infraRoot 'linux\bootstrap-host.sh'
if (-not (Test-Path -LiteralPath $hostBootstrap)) { throw "Host bootstrap missing: $hostBootstrap" }
$bootstrap = Get-Content -LiteralPath $hostBootstrap -Raw
foreach ($pattern in @('download.docker.com/linux/ubuntu', 'docker-ce', 'nvidia-container-toolkit', 'nvidia-ctk runtime configure', 'systemctl enable --now docker')) {
    if ($bootstrap -notmatch [regex]::Escape($pattern)) { throw "Host bootstrap contract missing: $pattern" }
}
if ($bootstrap -notmatch [regex]::Escape('precedence ::ffff:0:0/96  100')) {
    throw 'Host bootstrap must prefer IPv4 when mirrored WSL has no IPv6 route'
}
$stackInstaller = Join-Path $infraRoot 'linux\deploy-stack-files.sh'
if (-not (Test-Path -LiteralPath $stackInstaller)) { throw "Stack file installer missing: $stackInstaller" }
$composePath = Join-Path $infraRoot 'compose\compose.yaml'
$compose = Get-Content -LiteralPath $composePath -Raw
if ($compose -notmatch 'WEBUI_PORT:\s*8081' -or $compose -notmatch '8081:8081') {
    throw 'qBittorrent must use WEBUI_PORT 8081 and mapping 8081:8081'
}

$firewallPath = Join-Path $infraRoot 'windows\Configure-MediaFirewall.ps1'
if (-not (Test-Path -LiteralPath $firewallPath)) { throw "Firewall configurator missing: $firewallPath" }
$firewall = Get-Content -LiteralPath $firewallPath -Raw
foreach ($pattern in @('New-NetFirewallHyperVRule', '40E0AC32-46A5-438A-A0B2-2B479E8F2E90', 'publishedLanPorts', 'RemoteAddresses LocalSubnet', 'Profiles Private', "@('127.0.0.1', '::1')")) {
    if ($firewall -notmatch [regex]::Escape($pattern)) { throw "Firewall contract missing: $pattern" }
}
if ($firewall -match 'DefaultInboundAction\s+Allow') { throw 'Firewall must not broadly allow all WSL inbound traffic' }

foreach ($name in @('Start-MediaServer.ps1', 'Stop-MediaServer.ps1', 'Status-MediaServer.ps1', 'Update-MediaServer.ps1')) {
    $lifecyclePath = Join-Path $infraRoot "windows\$name"
    if (-not (Test-Path -LiteralPath $lifecyclePath)) { throw "Lifecycle script missing: $lifecyclePath" }
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($lifecyclePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "$name has parse errors: $($parseErrors.Message -join '; ')" }
}
$startScript = Get-Content -LiteralPath (Join-Path $infraRoot 'windows\Start-MediaServer.ps1') -Raw
if ($startScript -notmatch 'sleep' -or $startScript -notmatch 'infinity' -or $startScript -notmatch 'docker compose up -d') {
    throw 'Start script must keep WSL alive and start the compose stack'
}
$stopScript = Get-Content -LiteralPath (Join-Path $infraRoot 'windows\Stop-MediaServer.ps1') -Raw
if ($stopScript -notmatch 'docker compose down' -or $stopScript -notmatch '--terminate\s+MediaServer') {
    throw 'Stop script must stop the stack and only terminate MediaServer'
}
$updateScript = Get-Content -LiteralPath (Join-Path $infraRoot 'windows\Update-MediaServer.ps1') -Raw
foreach ($pattern in @('docker compose pull', 'docker compose config', 'docker compose up -d', 'previous-images')) {
    if ($updateScript -notmatch [regex]::Escape($pattern)) { throw "Update contract missing: $pattern" }
}

$configuratorPath = Join-Path $infraRoot 'linux\configure-stack.py'
if (-not (Test-Path -LiteralPath $configuratorPath)) { throw "Stack configurator missing: $configuratorPath" }
$configurator = Get-Content -LiteralPath $configuratorPath -Raw
foreach ($pattern in @('/data/library/movies', '/data/library/tv', '/data/library/music', 'HardwareAccelerationType', 'nvenc', 'awaiting_external_credentials')) {
    if ($configurator -notmatch [regex]::Escape($pattern)) { throw "Stack configurator contract missing: $pattern" }
}
$integrationVerifier = Join-Path $infraRoot 'linux\verify-integrations.py'
if (-not (Test-Path -LiteralPath $integrationVerifier)) { throw "Integration verifier missing: $integrationVerifier" }

$readmePath = Join-Path (Split-Path -Parent $infraRoot) 'README.md'
if (-not (Test-Path -LiteralPath $readmePath)) { throw "Operator README missing: $readmePath" }
$readme = Get-Content -LiteralPath $readmePath -Raw
foreach ($pattern in @('D:\WSL\Start-MediaServer.ps1', 'credentials', 'OpenSubtitles', 'LocalSubnet')) {
    if ($readme -notmatch [regex]::Escape($pattern)) { throw "README contract missing: $pattern" }
}

Write-Output 'PASS static media-stack contract'
