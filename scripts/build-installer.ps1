[CmdletBinding()]
param([string]$MakensisPath, [switch]$SkipFlutterBuild)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $root 'installer\.stage'
$dist = Join-Path $root 'dist'

if (-not $SkipFlutterBuild) {
  Push-Location (Join-Path $root 'flutter_app')
  try { flutter build windows --release; if ($LASTEXITCODE) { throw 'Flutter build failed.' } } finally { Pop-Location }
}

if (-not $MakensisPath) {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'),
    (Join-Path $env:ProgramFiles 'NSIS\makensis.exe')
  )
  $MakensisPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $MakensisPath) { throw 'makensis was not found. Install NSIS 3.x with: winget install NSIS.NSIS' }

Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$stage\app","$stage\stack\host-controller","$stage\stack\scripts","$stage\stack\runtime",$dist | Out-Null
Copy-Item (Join-Path $root 'flutter_app\build\windows\x64\runner\Release\*') "$stage\app" -Recurse
Copy-Item (Join-Path $root 'backend') "$stage\stack\backend" -Recurse
Remove-Item -Recurse -Force "$stage\stack\backend\test" -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root 'host-controller\src') "$stage\stack\host-controller\src" -Recurse
foreach ($name in @('auto-configure.ps1','bazarr_profile.py','bootstrap.sh','configure-services.sh','healthcheck.sh','install-host-controller.ps1','install-local.ps1','start-host-controller.ps1','uninstall-cleanup.ps1')) {
  Copy-Item (Join-Path $root "scripts\$name") "$stage\stack\scripts\$name"
}
Copy-Item (Join-Path $root 'docker-compose.yml') "$stage\stack\docker-compose.yml"
Copy-Item (Join-Path $root '.env.example') "$stage\stack\.env.example"
Copy-Item (Join-Path $root '.tools\node-v20.20.2-win-x64\node.exe') "$stage\stack\runtime\node.exe"

$private = Get-ChildItem $stage -Recurse -Force | Where-Object {
  $_.Name -eq '.env' -or $_.Name -eq '.env.compose' -or $_.Extension -in @('.db','.sqlite','.sqlite3')
}
if ($private) { throw "Staging contains a private environment file or database: $($private.FullName -join ', ')" }

$manifest = Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
[IO.File]::WriteAllLines((Join-Path $stage 'stage-manifest.txt'), $manifest, (New-Object Text.UTF8Encoding($false)))
& $MakensisPath '/WX' "/DSTAGE_DIR=$stage" "/DSOURCE_DIR=$root" "/DOUTPUT_FILE=$dist\install.exe" (Join-Path $root 'installer\media-control.nsi')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$dist\install.exe")) { throw 'NSIS build failed.' }
Write-Output "Created $dist\install.exe"
