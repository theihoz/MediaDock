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
