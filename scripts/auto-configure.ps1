$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent $PSScriptRoot
$EnvPath = Join-Path $ProjectDir '.env'

function Read-Env {
  $result = @{}
  Get-Content $EnvPath | ForEach-Object { if ($_ -match '^([^#=]+)=(.*)$') { $result[$matches[1]] = $matches[2] } }
  $result
}
function Api-Key($path) { ([xml](Get-Content $path -Raw)).Config.ApiKey }
function Set-Field($schema, $name, $value) {
  $field = $schema.fields | Where-Object name -eq $name | Select-Object -First 1
  if ($field) {
    if ($field.PSObject.Properties.Name -contains 'value') { $field.value = $value }
    else { $field | Add-Member -NotePropertyName value -NotePropertyValue $value }
  }
}
function Set-Property($object, $name, $value) {
  if ($object.PSObject.Properties.Name -contains $name) { $object.$name = $value }
  else { $object | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
function Invoke-Json($method, $uri, $headers, $body=$null) {
  $args = @{ Method=$method; Uri=$uri; Headers=$headers; ContentType='application/json' }
  if ($null -ne $body) { $args.Body = ($body | ConvertTo-Json -Depth 20) }
  Invoke-RestMethod @args
}

$envValues = Read-Env
$user = $envValues.LOCAL_ADMIN_USER; if (-not $user) { $user = 'admin' }
$password = $envValues.LOCAL_ADMIN_PASSWORD; if (-not $password) { $password = 'media1234' }

# Direct YIFY lookup is opt-in. Keep the URL fixed in backend configuration;
# Flutter can request fallback but cannot choose an arbitrary provider host.
if (-not $envValues.YIFY_DIRECT_ENABLED) { Add-Content $EnvPath 'YIFY_DIRECT_ENABLED=false' }
if (-not $envValues.YIFY_DIRECT_BASE_URL) { Add-Content $EnvPath 'YIFY_DIRECT_BASE_URL=' }
if (-not $envValues.SUBTITLE_TOKEN_SECRET -or $envValues.SUBTITLE_TOKEN_SECRET -eq 'replace-with-a-long-random-token') {
  $secret = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
  $lines = Get-Content $EnvPath
  if ($lines -match '^SUBTITLE_TOKEN_SECRET=') { $lines = $lines -replace '^SUBTITLE_TOKEN_SECRET=.*$', "SUBTITLE_TOKEN_SECRET=$secret" }
  else { $lines += "SUBTITLE_TOKEN_SECRET=$secret" }
  [IO.File]::WriteAllLines($EnvPath, $lines, (New-Object Text.UTF8Encoding($false)))
}

# qBittorrent: adopt the temporary first-run password, then configure a stable local account.
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$login = $null
try { $login = Invoke-WebRequest http://localhost:8080/api/v2/auth/login -Method Post -Body @{username=$user;password=$password} -WebSession $session -UseBasicParsing } catch {}
$loginText = if ($login -and $login.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($login.Content) } elseif ($login) { [string]$login.Content } else { '' }
if (-not $login -or -not ($login.StatusCode -eq 204 -or $loginText.Trim() -eq 'Ok.')) {
  $logs = (& cmd.exe /d /c 'docker logs media-stack-qbittorrent-1 2>&1') | Out-String
  if ($logs -notmatch 'temporary password[^:]*:\s*(\S+)') { throw 'Could not obtain qBittorrent temporary password' }
  $temporary = $matches[1]
  $login = Invoke-WebRequest http://localhost:8080/api/v2/auth/login -Method Post -Body @{username='admin';password=$temporary} -WebSession $session -UseBasicParsing
}
$prefs = @{ save_path='/data/downloads/complete'; temp_path_enabled=$true; temp_path='/data/downloads/incomplete'; web_ui_username=$user; web_ui_password=$password }
Invoke-WebRequest http://localhost:8080/api/v2/app/setPreferences -Method Post -Body @{json=($prefs|ConvertTo-Json -Compress)} -WebSession $session -UseBasicParsing | Out-Null
foreach ($category in @(@{name='movies';path='/data/downloads/complete/movies'},@{name='series';path='/data/downloads/complete/series'})) {
  try { Invoke-WebRequest http://localhost:8080/api/v2/torrents/createCategory -Method Post -Body @{category=$category.name;savePath=$category.path} -WebSession $session -UseBasicParsing | Out-Null } catch {}
}

function Ensure-Arr($name, $port, $key, $rootPath, $category, $categoryField) {
  $base = "http://localhost:$port/api/v3"
  $headers = @{'X-Api-Key'=$key}
  $roots = Invoke-Json GET "$base/rootfolder" $headers
  if (-not ($roots | Where-Object path -eq $rootPath)) { Invoke-Json POST "$base/rootfolder" $headers @{path=$rootPath} | Out-Null }
  $clients = Invoke-Json GET "$base/downloadclient" $headers
  if (-not ($clients | Where-Object name -eq 'Media qBittorrent')) {
    $schemas = Invoke-Json GET "$base/downloadclient/schema" $headers
    $schema = $schemas | Where-Object implementation -eq 'QBittorrent' | Select-Object -First 1
    if (-not $schema) { $schema = $schemas | Where-Object implementationName -eq 'qBittorrent' | Select-Object -First 1 }
    if (-not $schema) { throw "$name qBittorrent schema not found" }
    $schema.name='Media qBittorrent'; $schema.enable=$true
    Set-Field $schema host 'qbittorrent'; Set-Field $schema port 8080; Set-Field $schema username $user; Set-Field $schema password $password; Set-Field $schema $categoryField $category
    Invoke-Json POST "$base/downloadclient" $headers $schema | Out-Null
  }
}

$radarrKey = Api-Key 'D:\Media\config\radarr\config.xml'
$sonarrKey = Api-Key 'D:\Media\config\sonarr\config.xml'
$prowlarrKey = Api-Key 'D:\Media\config\prowlarr\config.xml'
Ensure-Arr radarr 7878 $radarrKey '/data/library/movies' movies movieCategory
Ensure-Arr sonarr 8989 $sonarrKey '/data/library/series' series tvCategory

$pHeaders = @{'X-Api-Key'=$prowlarrKey}; $pBase='http://localhost:9696/api/v1'
$existingApps = Invoke-Json GET "$pBase/applications" $pHeaders
foreach ($target in @(@{name='Radarr';url='http://radarr:7878';key=$radarrKey},@{name='Sonarr';url='http://sonarr:8989';key=$sonarrKey})) {
  if (-not ($existingApps | Where-Object name -eq $target.name)) {
    $applicationSchemas = Invoke-Json GET "$pBase/applications/schema" $pHeaders
    $schema = $applicationSchemas | Where-Object implementation -eq $target.name | Select-Object -First 1
    if (-not $schema) { throw "$($target.name) application schema not found" }
    Set-Property $schema name $target.name; Set-Property $schema enable $true
    Set-Field $schema prowlarrUrl 'http://prowlarr:9696'; Set-Field $schema baseUrl $target.url; Set-Field $schema apiKey $target.key; Set-Field $schema syncLevel 'fullSync'
    Invoke-Json POST "$pBase/applications" $pHeaders $schema | Out-Null
  }
}

# Internet Archive is retained when already configured, but disabled because its
# upstream search frequently times out and blocks Radarr's complete result set.
$existingIndexers = Invoke-Json GET "$pBase/indexer" $pHeaders
$archive = $existingIndexers | Where-Object name -eq 'Internet Archive' | Select-Object -First 1
if ($archive -and $archive.enable) {
  Set-Property $archive enable $false
  Invoke-Json PUT "$pBase/indexer/$($archive.id)" $pHeaders $archive | Out-Null
}

# YTS is explicitly requested for authorized/local use. Its API does not
# reliably publish seed counts, so set the per-indexer application minimum to
# zero; otherwise Radarr rejects every returned release as "0 seeders".
if (-not ($existingIndexers | Where-Object name -eq 'YTS')) {
  $indexerSchemas = Invoke-Json GET "$pBase/indexer/schema" $pHeaders
  $yts = $indexerSchemas | Where-Object name -eq 'YTS' | Select-Object -First 1
  if ($yts) {
    $profiles = Invoke-Json GET "$pBase/appprofile" $pHeaders
    Set-Property $yts name 'YTS'; Set-Property $yts enable $true
    Set-Property $yts appProfileId $profiles[0].id
    Set-Field $yts baseUrl 'https://yts.gg/'
    Set-Field $yts apiurl 'movies-api.accel.li'
    Set-Field $yts 'torrentBaseSettings.appMinimumSeeders' 0
    Invoke-Json POST "$pBase/indexer" $pHeaders $yts | Out-Null
  }
}

$appProfiles = Invoke-Json GET "$pBase/appprofile" $pHeaders
foreach ($profile in $appProfiles) {
  if ($profile.minimumSeeders -ne 0) {
    $profile.minimumSeeders = 0
    Invoke-Json PUT "$pBase/appprofile/$($profile.id)" $pHeaders $profile | Out-Null
  }
}
Invoke-Json POST "$pBase/command" $pHeaders @{name='ApplicationIndexerSync'} | Out-Null

# Jellyfin first-run wizard and API token for the gateway.
$public = Invoke-RestMethod http://localhost:8096/System/Info/Public
if (-not $public.StartupWizardCompleted) {
  Invoke-Json POST http://localhost:8096/Startup/Configuration @{} @{UICulture='en-US';MetadataCountryCode='US';PreferredMetadataLanguage='en'} | Out-Null
  Invoke-Json POST http://localhost:8096/Startup/User @{} @{Name=$user;Password=$password} | Out-Null
  Invoke-Json POST http://localhost:8096/Startup/RemoteAccess @{} @{EnableRemoteAccess=$false;EnableAutomaticPortMapping=$false} | Out-Null
  Invoke-Json POST http://localhost:8096/Startup/Complete @{} @{} | Out-Null
}
$authHeader = @{Authorization='MediaBrowser Client="MediaControl", Device="Windows", DeviceId="media-control-local", Version="1.0"'}
$auth = Invoke-Json POST http://localhost:8096/Users/AuthenticateByName $authHeader @{Username=$user;Pw=$password}
$token = $auth.AccessToken
$jHeaders = @{'X-Emby-Token'=$token}
$folders = Invoke-Json GET http://localhost:8096/Library/VirtualFolders $jHeaders
if (-not ($folders | Where-Object Name -eq 'Movies')) { Invoke-RestMethod 'http://localhost:8096/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fdata%2Flibrary%2Fmovies&refreshLibrary=true' -Method Post -Headers $jHeaders | Out-Null }
if (-not ($folders | Where-Object Name -eq 'Series')) { Invoke-RestMethod 'http://localhost:8096/Library/VirtualFolders?name=Series&collectionType=tvshows&paths=%2Fdata%2Flibrary%2Fseries&refreshLibrary=true' -Method Post -Headers $jHeaders | Out-Null }

$lines = Get-Content $EnvPath
if ($lines -match '^JELLYFIN_API_KEY=') { $lines = $lines -replace '^JELLYFIN_API_KEY=.*$', "JELLYFIN_API_KEY=$token" } else { $lines += "JELLYFIN_API_KEY=$token" }
[IO.File]::WriteAllLines($EnvPath, $lines, (New-Object Text.UTF8Encoding($false)))
$composeEnvPath = Join-Path $ProjectDir '.env.compose'
if (Test-Path $composeEnvPath) {
  $composeLines = Get-Content $composeEnvPath
  if ($composeLines -match '^JELLYFIN_API_KEY=') { $composeLines = $composeLines -replace '^JELLYFIN_API_KEY=.*$', "JELLYFIN_API_KEY=$token" }
  else { $composeLines += "JELLYFIN_API_KEY=$token" }
  $freshEnv = Read-Env
  foreach ($name in @('YIFY_DIRECT_ENABLED','YIFY_DIRECT_BASE_URL','SUBTITLE_TOKEN_SECRET')) {
    $value = $freshEnv[$name]
    if ($composeLines -match "^$name=") { $composeLines = $composeLines -replace "^$name=.*$", "$name=$value" }
    else { $composeLines += "$name=$value" }
  }
  [IO.File]::WriteAllLines($composeEnvPath, $composeLines, (New-Object Text.UTF8Encoding($false)))
}

# Bazarr: connect Arr services and enable free, credential-less movie providers.
$bazarrPath = 'D:\Media\config\bazarr\config\config.yaml'
$section = ''
$skipProviderLines = $false
$bazarrLines = New-Object Collections.Generic.List[string]
foreach ($line in [IO.File]::ReadAllLines($bazarrPath)) {
  if ($skipProviderLines -and $line -match '^  - ') { continue }
  $skipProviderLines = $false
  if ($line -match '^([a-zA-Z][a-zA-Z0-9_]*):\s*$') { $section = $matches[1] }
  if ($section -eq 'general' -and $line -match '^  enabled_providers:') {
    $bazarrLines.Add('  enabled_providers:'); $bazarrLines.Add('  - gestdown'); $bazarrLines.Add('  - yifysubtitles'); $skipProviderLines = $true; continue
  }
  if ($section -eq 'general' -and $line -match '^  use_radarr:') { $bazarrLines.Add('  use_radarr: true'); continue }
  if ($section -eq 'general' -and $line -match '^  use_sonarr:') { $bazarrLines.Add('  use_sonarr: true'); continue }
  if ($section -eq 'radarr' -and $line -match '^  apikey:') { $bazarrLines.Add("  apikey: $radarrKey"); continue }
  if ($section -eq 'radarr' -and $line -match '^  ip:') { $bazarrLines.Add('  ip: radarr'); continue }
  if ($section -eq 'sonarr' -and $line -match '^  apikey:') { $bazarrLines.Add("  apikey: $sonarrKey"); continue }
  if ($section -eq 'sonarr' -and $line -match '^  ip:') { $bazarrLines.Add('  ip: sonarr'); continue }
  $bazarrLines.Add($line)
}
[IO.File]::WriteAllLines($bazarrPath, $bazarrLines, (New-Object Text.UTF8Encoding($false)))
docker compose --env-file (Join-Path $ProjectDir '.env.compose') restart bazarr | Out-Null
docker compose --env-file (Join-Path $ProjectDir '.env.compose') up -d --force-recreate api | Out-Null

Write-Output 'Configured qBittorrent, Radarr, Sonarr, Prowlarr (Internet Archive + YTS), Bazarr and Jellyfin.'
