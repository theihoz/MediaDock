[CmdletBinding()]
param(
  [string]$ProjectDir = "$env:ProgramData\MediaControl\stack",
  [string]$AppDir = "$env:ProgramFiles\Media Control",
  [string]$MediaRoot,
  [switch]$PreflightOnly,
  [switch]$SkipPreflight,
  [switch]$SkipFirewall,
  [switch]$RepairProviders
)

$ErrorActionPreference = 'Stop'

function Test-Prerequisites([string]$RequestedMediaRoot) {
  if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Major -lt 10) {
    throw 'Media Control requires 64-bit Windows 10 or newer.'
  }
  $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
  if (-not $wsl) { throw 'WSL2 is missing. Install it from https://learn.microsoft.com/windows/wsl/install' }
  $distros = ((& $wsl.Source -l -q 2>$null) -join "`n") -replace "`0", ''
  if ($distros -notmatch '(?im)^Ubuntu(?:\s|$)') { throw 'Ubuntu for WSL is missing. Run: wsl --install -d Ubuntu' }
  $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
  $dockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (-not $docker -and -not (Test-Path -LiteralPath $dockerDesktop)) {
    throw 'Docker Desktop is missing. Install it from https://www.docker.com/products/docker-desktop/'
  }
  $runtime = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
  if ($runtime.Installed -ne 1) {
    throw 'Microsoft Visual C++ 2015-2022 x64 runtime is missing: https://aka.ms/vs/17/release/vc_redist.x64.exe'
  }
  $fullRoot = [IO.Path]::GetFullPath($RequestedMediaRoot)
  $qualifier = Split-Path -Qualifier $fullRoot
  if (-not $qualifier -or -not (Test-Path -LiteralPath $qualifier)) { throw "Media drive is unavailable: $fullRoot" }
  $drive = Get-PSDrive ($qualifier.TrimEnd('\').TrimEnd(':'))
  if ($drive.Free -lt 10GB) { throw "Media drive needs at least 10 GB free: $qualifier" }
  $probe = Join-Path $qualifier ".media-control-write-$([guid]::NewGuid().ToString('N')).tmp"
  try { [IO.File]::WriteAllText($probe, 'probe') } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

function New-HexSecret {
  $bytes = New-Object byte[] 24
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Convert-ToWslPath([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "Cannot convert path to WSL: $full" }
  return "/mnt/$($matches[1].ToLower())/$($matches[2].Replace('\', '/'))"
}

if (-not $MediaRoot) {
  $existingCompose = Join-Path $ProjectDir '.env.compose'
  if (Test-Path -LiteralPath $existingCompose) {
    $rootLine = Get-Content -LiteralPath $existingCompose | Where-Object { $_ -match '^MEDIA_ROOT=' } | Select-Object -First 1
    if ($rootLine -match '^MEDIA_ROOT=(.+)$') { $MediaRoot = $matches[1] }
  }
  if (-not $MediaRoot) {
    $registered = Get-ItemProperty 'HKLM:\Software\MediaControl' -Name MediaRoot -ErrorAction SilentlyContinue
    if ($registered) { $MediaRoot = $registered.MediaRoot }
  }
  if (-not $MediaRoot) { $MediaRoot = 'D:\Media' }
}
$MediaRoot = [IO.Path]::GetFullPath($MediaRoot).TrimEnd('\')

if (-not $SkipPreflight) { Test-Prerequisites $MediaRoot }
if ($PreflightOnly) { exit 0 }

$example = Join-Path $ProjectDir '.env.example'
$envPath = Join-Path $ProjectDir '.env'
$composeEnv = Join-Path $ProjectDir '.env.compose'
if (-not (Test-Path -LiteralPath $example)) { throw "Missing installer payload: $example" }

New-Item -ItemType Directory -Force -Path $ProjectDir | Out-Null
$dockerMediaRoot = $MediaRoot.Replace('\', '/')
foreach ($relative in @(
  'downloads\incomplete', 'downloads\complete', 'library\movies', 'library\series',
  'subtitles', 'config\bootstrap', 'cache', 'backups'
)) { New-Item -ItemType Directory -Force -Path (Join-Path $mediaRoot $relative) | Out-Null }

$installIdPath = Join-Path $ProjectDir '.installation-id'
$installId = if (Test-Path -LiteralPath $installIdPath) {
  (Get-Content -Raw -LiteralPath $installIdPath).Trim()
} else { [guid]::NewGuid().ToString('D') }
if ($installId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Invalid installation ID.' }
[IO.File]::WriteAllText($installIdPath, $installId, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $mediaRoot '.media-control-root'), $installId, (New-Object Text.UTF8Encoding($false)))

if (-not (Test-Path -LiteralPath $envPath)) {
  $values = @{
    HOST_CONTROLLER_TOKEN = New-HexSecret
    SUBTITLE_TOKEN_SECRET = New-HexSecret
    TV_DOWNLOAD_TOKEN_SECRET = New-HexSecret
  }
  $lines = foreach ($line in Get-Content -LiteralPath $example) {
    if ($line -match '^([^#=]+)=(.*)$' -and $values.ContainsKey($matches[1])) { "$($matches[1])=$($values[$matches[1]])" }
    elseif ($line -match '^MEDIA_ROOT=') { "MEDIA_ROOT=$(Convert-ToWslPath $MediaRoot)" }
    elseif ($line -match '^MEDIA_ROOT_DOCKER=') { "MEDIA_ROOT_DOCKER=$dockerMediaRoot" }
    elseif ($line -match '^WSL_PROJECT_DIR=') { "WSL_PROJECT_DIR=$(Convert-ToWslPath $ProjectDir)" }
    else { $line }
  }
  [IO.File]::WriteAllLines($envPath, $lines, (New-Object Text.UTF8Encoding($false)))
}

$requiredEnvironment = [ordered]@{
  MEDIA_ROOT = Convert-ToWslPath $MediaRoot
  MEDIA_ROOT_DOCKER = $dockerMediaRoot
  WSL_DISTRO = 'Ubuntu'
  WSL_PROJECT_DIR = Convert-ToWslPath $ProjectDir
}
$envLines = @(Get-Content -LiteralPath $envPath)
if (-not ($envLines -match '^YTS_MOVIE_API_URL=')) { $envLines += 'YTS_MOVIE_API_URL=https://movies-api.accel.li' }
foreach ($key in $requiredEnvironment.Keys) {
  $found = $false
  $envLines = @($envLines | ForEach-Object {
    if ($_ -match "^$([regex]::Escape($key))=") { $found = $true; "$key=$($requiredEnvironment[$key])" } else { $_ }
  })
  if (-not $found) { $envLines += "$key=$($requiredEnvironment[$key])" }
}
[IO.File]::WriteAllLines($envPath, $envLines, (New-Object Text.UTF8Encoding($false)))

$composeLines = foreach ($line in Get-Content -LiteralPath $envPath) {
  if ($line -match '^MEDIA_ROOT(?:_DOCKER)?=') { "$($line.Split('=')[0])=$dockerMediaRoot" } else { $line }
}
[IO.File]::WriteAllLines($composeEnv, $composeLines, (New-Object Text.UTF8Encoding($false)))

if (-not $SkipFirewall) {
  & (Join-Path $ProjectDir 'scripts\install-host-controller.ps1')
  if ($LASTEXITCODE) { throw 'Failed to configure the local controller.' }
}

$bootstrapMarker = Join-Path $MediaRoot 'config\bootstrap\.bootstrap-complete'
if ($RepairProviders -and (Test-Path -LiteralPath $bootstrapMarker)) {
  $bootstrap = Convert-ToWslPath (Join-Path $ProjectDir 'scripts\bootstrap.sh')
  & wsl.exe -d Ubuntu -- bash $bootstrap --repair
  if ($LASTEXITCODE) { throw 'Provider repair failed.' }
}

Write-Output "Media Control prepared at $AppDir"
