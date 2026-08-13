$ErrorActionPreference = 'Stop'

$ProjectDir = Split-Path -Parent $PSScriptRoot
$EnvPath = Join-Path $ProjectDir '.env'
$Launcher = Join-Path $PSScriptRoot 'start-host-controller.ps1'
if (-not (Test-Path -LiteralPath $EnvPath)) { throw "Missing private environment file: $EnvPath" }

$values = @{}
Get-Content -LiteralPath $EnvPath | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
}
$token = $values['HOST_CONTROLLER_TOKEN']
if ([string]::IsNullOrWhiteSpace($token)) { throw 'HOST_CONTROLLER_TOKEN is missing' }

$ConfigDir = Join-Path $env:LOCALAPPDATA 'MediaControl'
$ConfigPath = Join-Path $ConfigDir 'config.json'
$TempPath = "$ConfigPath.tmp"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$configJson = @{
  gateway = 'http://localhost:3000'
  controller = 'http://127.0.0.1:3210'
  token = $token
  controllerLauncher = $Launcher
} | ConvertTo-Json
[IO.File]::WriteAllText($TempPath, $configJson, (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $TempPath -Destination $ConfigPath -Force
Write-Output "Media Control local configuration installed at $ConfigPath"

# Jellyfin is exposed only to devices on the current private LAN. These rules
# do not create external forwarding and do not start Docker or the media stack.
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  foreach ($rule in @(
    @{Name='Media Control Jellyfin HTTP';Protocol='TCP';Port=8096},
    @{Name='Media Control Jellyfin Discovery';Protocol='UDP';Port=7359}
  )) {
    Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol $rule.Protocol -LocalPort $rule.Port -Profile Private -RemoteAddress LocalSubnet | Out-Null
  }
  Write-Output 'Jellyfin Private/LocalSubnet firewall rules installed.'
} else {
  Write-Warning 'Run this installer once as Administrator to add the Jellyfin LAN firewall rules.'
}
