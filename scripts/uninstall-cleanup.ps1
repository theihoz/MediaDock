[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$MediaRoot,
  [Parameter(Mandatory)][string]$ProjectDir,
  [Parameter(Mandatory)][string]$ExpectedInstallationId,
  [switch]$SkipDocker,
  [switch]$SkipSystemCleanup
)

$ErrorActionPreference = 'Stop'

function Remove-TreeSafely([string]$Root) {
  foreach ($item in Get-ChildItem -Force -LiteralPath $Root) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      [IO.Directory]::Delete($item.FullName)
    } elseif ($item.PSIsContainer) {
      Remove-TreeSafely $item.FullName
      Remove-Item -Force -LiteralPath $item.FullName
    } else {
      Remove-Item -Force -LiteralPath $item.FullName
    }
  }
  Remove-Item -Force -LiteralPath $Root
}

function Assert-OwnedMediaRoot {
  $script:MediaRoot = [IO.Path]::GetFullPath($MediaRoot).TrimEnd('\')
  $root = [IO.Path]::GetPathRoot($script:MediaRoot).TrimEnd('\')
  if ($script:MediaRoot -eq $root -or -not (Test-Path -LiteralPath $script:MediaRoot -PathType Container)) {
    throw "Unsafe media root: $script:MediaRoot"
  }
  $marker = Join-Path $script:MediaRoot '.media-control-root'
  $actual = if (Test-Path -LiteralPath $marker) { (Get-Content -Raw -LiteralPath $marker).Trim() } else { '' }
  if (-not $ExpectedInstallationId -or $actual -ne $ExpectedInstallationId) {
    throw 'Media root ownership marker does not match this installation.'
  }
}

function Stop-Controller {
  $pidPath = Join-Path $env:LOCALAPPDATA 'MediaControl\controller.pid'
  if (-not (Test-Path -LiteralPath $pidPath)) { return }
  $controllerPid = [int](Get-Content -Raw -LiteralPath $pidPath)
  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$controllerPid" -ErrorAction SilentlyContinue
  if ($process -and $process.CommandLine -like "*$ProjectDir*host-controller*server.mjs*") {
    Stop-Process -Id $controllerPid -Force
  }
}

function Find-Docker {
  $command = Get-Command docker.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $candidate = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
  if (Test-Path -LiteralPath $candidate) { return $candidate }
  throw 'Docker CLI is unavailable; Docker resources were not removed.'
}

function Invoke-Docker([string]$Docker, [string[]]$DockerArguments) {
  & $Docker @DockerArguments | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Docker command failed: $($DockerArguments -join ' ')" }
}

function Remove-DockerResources {
  $docker = Find-Docker
  & $docker info | Out-Null
  if ($LASTEXITCODE -ne 0) {
    $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path -LiteralPath $desktop)) { throw 'Docker Desktop is not running.' }
    Start-Process -FilePath $desktop -WindowStyle Hidden
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 2
      & $docker info 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
    if (-not $ready) { throw 'Docker Desktop did not become ready.' }
  }

  $envFile = Join-Path $ProjectDir '.env.compose'
  $images = @(& $docker compose --env-file $envFile -f (Join-Path $ProjectDir 'docker-compose.yml') images -q 2>$null) | Where-Object { $_ }
  Invoke-Docker $docker @('compose', '--env-file', $envFile, '-f', (Join-Path $ProjectDir 'docker-compose.yml'), 'down', '--remove-orphans')
  foreach ($volume in @('media-stack-postgres-data', 'media-stack-redis-data')) {
    & $docker volume inspect $volume 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Invoke-Docker $docker @('volume', 'rm', $volume) }
  }
  foreach ($image in ($images | Sort-Object -Unique)) {
    $users = @(& $docker ps -aq --filter "ancestor=$image" 2>$null) | Where-Object { $_ }
    if ($users.Count -eq 0) { & $docker image rm $image 2>$null | Out-Null }
  }
}

Assert-OwnedMediaRoot
if (-not $SkipDocker) { Remove-DockerResources }
if (-not $SkipSystemCleanup) {
  Stop-Controller
  Get-NetFirewallRule -DisplayName 'Media Control Jellyfin HTTP','Media Control Jellyfin Discovery' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  Remove-Item -Recurse -Force -LiteralPath (Join-Path $env:LOCALAPPDATA 'MediaControl') -ErrorAction SilentlyContinue
}
Remove-TreeSafely $MediaRoot
