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
$env:WSL_DISTRO = if ($values['WSL_DISTRO']) { $values['WSL_DISTRO'] } else { 'Ubuntu' }
$env:WSL_PROJECT_DIR = $values['WSL_PROJECT_DIR']
$composeValues = @{}
Get-Content $env:COMPOSE_ENV_FILE | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') { $composeValues[$matches[1]] = $matches[2] }
}
$env:MEDIA_ROOT = if ($composeValues['MEDIA_ROOT']) { $composeValues['MEDIA_ROOT'] } else { 'D:/Media' }
$dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
$dockerDesktopCli = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
$env:DOCKER_EXE = if ($dockerCommand) { $dockerCommand.Source } elseif (Test-Path -LiteralPath $dockerDesktopCli) { $dockerDesktopCli } else { 'docker' }
$ConfigDir = Join-Path $env:LOCALAPPDATA 'MediaControl'
$PidPath = Join-Path $ConfigDir 'controller.pid'
$BundledNode = Join-Path $ProjectDir 'runtime\node.exe'
$NodeExe = if (Test-Path -LiteralPath $BundledNode) { $BundledNode } else { (Get-Command node -ErrorAction Stop).Source }
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
[IO.File]::WriteAllText($PidPath, "$PID", (New-Object Text.UTF8Encoding($false)))
try {
  & $NodeExe (Join-Path $ProjectDir 'host-controller\src\server.mjs')
} finally {
  Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
