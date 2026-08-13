$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent $PSScriptRoot
$BootstrapPath = Join-Path $PSScriptRoot 'bootstrap.sh'
$bootstrap = Get-Content -Raw -LiteralPath $BootstrapPath

if ($bootstrap -notmatch '(?m)^"\$\{DOCKER\[@\]\}" compose --env-file "\$COMPOSE_ENV_FILE" stop$') {
  throw 'bootstrap does not stop the media stack after configuration'
}
if ($bootstrap -notmatch 'Setup complete\. Media stack is stopped\. Start it from Media Control or Docker Desktop\.') {
  throw 'bootstrap does not report the final stopped state'
}

$installers = Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
  Where-Object { $_.Name -ne 'test-manual-start.ps1' } |
  ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }
$forbidden = 'Register-ScheduledTask|schtasks(?:\.exe)?\s+/create|CurrentVersion\\Run|Startup\\|New-Service'
if (($installers -join "`n") -match $forbidden) {
  throw 'an installer enables automatic Windows startup'
}

$configJson = docker compose --env-file (Join-Path $ProjectDir '.env.compose') config --format json
$config = $configJson | ConvertFrom-Json
$automatic = @($config.services.PSObject.Properties | Where-Object { $_.Value.restart -ne 'no' })
if ($automatic.Count -gt 0) {
  throw "automatic restart policy found: $($automatic.Name -join ', ')"
}

Write-Output 'PASS: bootstrap ends stopped, installers do not register auto-start, and Compose restart is disabled'
