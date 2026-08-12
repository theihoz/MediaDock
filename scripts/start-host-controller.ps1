$ErrorActionPreference = 'Stop'
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
$env:DOCKER_EXE = (Get-Command docker.exe).Source
node (Join-Path $ProjectDir 'host-controller\src\server.mjs')
