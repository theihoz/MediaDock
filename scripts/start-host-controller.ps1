$ErrorActionPreference = 'Stop'
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\MediaControlHostController', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$ProjectDir = Split-Path -Parent $PSScriptRoot
$EnvPath = Join-Path $ProjectDir '.env'
$values = @{}
Get-Content $EnvPath | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
}
$env:HOST_CONTROLLER_TOKEN = $values['HOST_CONTROLLER_TOKEN']
$env:HOST_CONTROLLER_PORT = '3210'
$env:MEDIA_PROJECT_DIR = $ProjectDir
$env:COMPOSE_ENV_FILE = Join-Path $ProjectDir '.env.compose'
$composeValues = @{}
Get-Content $env:COMPOSE_ENV_FILE | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') { $composeValues[$matches[1]] = $matches[2] }
}
$env:MEDIA_ROOT = if ($composeValues['MEDIA_ROOT']) { $composeValues['MEDIA_ROOT'] } else { 'D:/Media' }
$dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
$env:DOCKER_EXE = if ($dockerCommand) { $dockerCommand.Source } else { 'docker' }
try {
  node (Join-Path $ProjectDir 'host-controller\src\server.mjs')
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
