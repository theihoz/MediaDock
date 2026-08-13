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
  $object | Add-Member -Force -NotePropertyName $name -NotePropertyValue $value
}
function Find-Item($items, $property, $value) {
  foreach ($item in $items) {
    if ($item -is [System.Array]) {
      $nested = Find-Item $item $property $value
      if ($nested) { return $nested }
      continue
    }
    if ($item.$property -eq $value) { return $item }
  }
  return $null
}
function Invoke-Json($method, $uri, $headers, $body=$null) {
  $args = @{ Method=$method; Uri=$uri; Headers=$headers; ContentType='application/json' }
  if ($null -ne $body) { $args.Body = ($body | ConvertTo-Json -Depth 20) }
  Invoke-RestMethod @args
}

$envValues = Read-Env
$user = $envValues.LOCAL_ADMIN_USER; if (-not $user) { $user = 'admin' }
$password = $envValues.LOCAL_ADMIN_PASSWORD; if (-not $password) { $password = 'media1234' }

# Seed the protected last-good discovery cache without starting any service.
$trendingCache = 'D:\Media\cache\trending.json'
$cachedTrendingCount = 0
if (Test-Path -LiteralPath $trendingCache) {
  try { $cachedTrendingCount = @((Get-Content $trendingCache -Raw | ConvertFrom-Json)).Count } catch {}
}
if ($cachedTrendingCount -lt 180) {
  try {
    $popular = Invoke-RestMethod 'https://movies-api.accel.li/api/v2/list_movies.json?limit=80&sort_by=download_count' -TimeoutSec 8
    $cards = @($popular.data.movies | ForEach-Object {
      @{tmdbId=0;ytsId=[int]$_.id;mediaType='movie';title=$_.title;year=[int]$_.year;overview=$_.summary;poster=$_.medium_cover_image;runtime=$_.runtime;genres=@($_.genres);inLibrary=$false;rating=$_.rating}
    })
    if ($cards.Count -gt 0) {
      New-Item -ItemType Directory -Force -Path (Split-Path $trendingCache -Parent) | Out-Null
      [IO.File]::WriteAllText($trendingCache, ($cards | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
    }
  } catch { Write-Warning 'Could not seed trending cache; backend will retry when Discover opens.' }
}

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
if (-not $envValues.YTS_OFFICIAL_TV_URL) { Add-Content $EnvPath 'YTS_OFFICIAL_TV_URL=https://en.yts-official.com/' }
if (-not $envValues.YTS_OFFICIAL_TV_ENABLED) { Add-Content $EnvPath 'YTS_OFFICIAL_TV_ENABLED=true' }
if (-not $envValues.TV_DOWNLOAD_TOKEN_SECRET -or $envValues.TV_DOWNLOAD_TOKEN_SECRET -eq 'replace-with-a-long-random-token') {
  $tvSecret = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
  $lines = Get-Content $EnvPath
  if ($lines -match '^TV_DOWNLOAD_TOKEN_SECRET=') { $lines = $lines -replace '^TV_DOWNLOAD_TOKEN_SECRET=.*$', "TV_DOWNLOAD_TOKEN_SECRET=$tvSecret" }
  else { $lines += "TV_DOWNLOAD_TOKEN_SECRET=$tvSecret" }
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

# TV searches run all configured providers concurrently. Enable the public
# source here; backend deadlines ensure it cannot block successful providers.
$existingIndexers = Invoke-Json GET "$pBase/indexer" $pHeaders
$tags = @(Invoke-Json GET "$pBase/tag" $pHeaders)
$flareTag = Find-Item $tags 'label' 'flaresolverr'
if (-not $flareTag) { $flareTag = Invoke-Json POST "$pBase/tag" $pHeaders @{label='flaresolverr'} }
$nyaaTag = Find-Item $tags 'label' 'nyaa-anime'
if (-not $nyaaTag) { $nyaaTag = Invoke-Json POST "$pBase/tag" $pHeaders @{label='nyaa-anime'} }
$proxies = @(Invoke-Json GET "$pBase/indexerProxy" $pHeaders)
$flareProxy = $proxies | Where-Object { $_.name -eq 'Media FlareSolverr' } | Select-Object -First 1
if (-not $flareProxy) {
  $proxySchemas = Invoke-Json GET "$pBase/indexerProxy/schema" $pHeaders
  $proxy = $proxySchemas | Where-Object implementation -eq 'FlareSolverr' | Select-Object -First 1
  Set-Property $proxy name 'Media FlareSolverr'; Set-Property $proxy tags @($flareTag.id)
  Set-Field $proxy host 'http://flaresolverr:8191/'
  Invoke-Json POST "$pBase/indexerProxy" $pHeaders $proxy | Out-Null
}

function Ensure-NyaaIndexer($name, $baseUrl, $useFlareSolverr) {
  $existing = Find-Item $existingIndexers 'name' $name
  if ($existing) {
    $target = $existing
  } else {
    $schemas = Invoke-Json GET "$pBase/indexer/schema" $pHeaders
    $schema = Find-Item $schemas 'name' 'Nyaa.si'
    if (-not $schema) { $schema = Find-Item $schemas 'name' 'Nyaa' }
    if (-not $schema) {
      Write-Warning "$name`: needs_manual_configuration (Nyaa schema unavailable)"
      return
    }
    $target = $schema | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  }
  Set-Property $target name $name
  Set-Property $target enable $true
  $profiles = Invoke-Json GET "$pBase/appprofile" $pHeaders
  if ($profiles.Count -gt 0) { Set-Property $target appProfileId $profiles[0].id }
  Set-Field $target baseUrl $baseUrl
  Set-Field $target sonarr_compatibility $true
  Set-Field $target radarr_compatibility $true
  Set-Field $target prefer_magnet_links $true
  Set-Field $target 'torrentBaseSettings.appMinimumSeeders' 0
  if (-not ($target.fields | Where-Object { $_.name -eq 'baseUrl' })) {
    Write-Warning "$name`: needs_manual_configuration (baseUrl is not editable)"
    return
  }
  if ($useFlareSolverr) { Set-Property $target tags @($flareTag.id, $nyaaTag.id) }
  else { Set-Property $target tags @($nyaaTag.id) }
  if ($existing) { Invoke-Json PUT "$pBase/indexer/$($target.id)?forceSave=true" $pHeaders $target | Out-Null }
  else { Invoke-Json POST "$pBase/indexer?forceSave=true" $pHeaders $target | Out-Null }
}

Ensure-NyaaIndexer 'Nyaa.si' 'https://nyaa.si/' $true
Ensure-NyaaIndexer 'Nyaa.land' 'https://nyaa.land/' $true

$archive = $existingIndexers | Where-Object name -eq 'Internet Archive' | Select-Object -First 1
if ($archive -and -not $archive.enable) {
  Set-Property $archive enable $true
  Invoke-Json PUT "$pBase/indexer/$($archive.id)" $pHeaders $archive | Out-Null
}

# Prowlarr currently has no built-in Public Domain Torrents definition and the
# site does not expose a compatible Torznab/RSS feed. Keep this visible as an
# explicit manual-feed state rather than adding a fragile scraper.
$publicDomainSchema = (Invoke-Json GET "$pBase/indexer/schema" $pHeaders) | Where-Object { $_.name -eq 'Public Domain Torrents' } | Select-Object -First 1
if (-not $publicDomainSchema) { Write-Warning 'Public Domain Torrents: needs_manual_feed (no compatible Prowlarr schema)' }

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

# EZTV is the first Sonarr/Prowlarr fallback when YTS has no exact TV release.
$existingEztv = $existingIndexers | Where-Object { $_.name -eq 'EZTV' } | Select-Object -First 1
if (-not $existingEztv) {
  $indexerSchemas = Invoke-Json GET "$pBase/indexer/schema" $pHeaders
  $eztv = $indexerSchemas | Where-Object name -eq 'EZTV' | Select-Object -First 1
  if ($eztv) {
    $profiles = Invoke-Json GET "$pBase/appprofile" $pHeaders
    Set-Property $eztv name 'EZTV'; Set-Property $eztv enable $true
    Set-Property $eztv tags @($flareTag.id)
    Set-Property $eztv appProfileId $profiles[0].id
    Set-Field $eztv baseUrl 'https://eztvx.to/'
    Invoke-Json POST "$pBase/indexer" $pHeaders $eztv | Out-Null
  }
} elseif (-not $existingEztv.enable) {
  Set-Property $existingEztv enable $true
  Invoke-Json PUT "$pBase/indexer/$($existingEztv.id)" $pHeaders $existingEztv | Out-Null
}

# Fourth TV source, especially useful for anime where EZTV coverage is sparse.
# Tokyo Toshokan is used because it is reachable without credentials on this network.
$existingTokyo = $existingIndexers | Where-Object { $_.name -eq 'Tokyo Toshokan' } | Select-Object -First 1
if (-not $existingTokyo) {
  $indexerSchemas = Invoke-Json GET "$pBase/indexer/schema" $pHeaders
  $tokyo = $indexerSchemas | Where-Object name -eq 'Tokyo Toshokan' | Select-Object -First 1
  if ($tokyo) {
    $profiles = Invoke-Json GET "$pBase/appprofile" $pHeaders
    Set-Property $tokyo name 'Tokyo Toshokan'; Set-Property $tokyo enable $true
    Set-Property $tokyo appProfileId $profiles[0].id
    Set-Field $tokyo baseUrl 'https://www.tokyotosho.info/'
    Invoke-Json POST "$pBase/indexer" $pHeaders $tokyo | Out-Null
  }
} elseif (-not $existingTokyo.enable) {
  Set-Property $existingTokyo enable $true
  Invoke-Json PUT "$pBase/indexer/$($existingTokyo.id)?forceSave=true" $pHeaders $existingTokyo | Out-Null
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
  Invoke-Json POST http://localhost:8096/Startup/RemoteAccess @{} @{EnableRemoteAccess=$true;EnableAutomaticPortMapping=$false} | Out-Null
  Invoke-Json POST http://localhost:8096/Startup/Complete @{} @{} | Out-Null
}
$authHeader = @{Authorization='MediaBrowser Client="MediaControl", Device="Windows", DeviceId="media-control-local", Version="1.0"'}
$auth = Invoke-Json POST http://localhost:8096/Users/AuthenticateByName $authHeader @{Username=$user;Pw=$password}
$token = $auth.AccessToken
$jHeaders = @{'X-Emby-Token'=$token}
Write-Output 'Configuring Jellyfin LAN access...'
$jellyfinConfig = Invoke-Json GET http://localhost:8096/System/Configuration/network $jHeaders
Set-Property $jellyfinConfig EnableRemoteAccess $true
Set-Property $jellyfinConfig EnableUPnP $false
Set-Property $jellyfinConfig EnableHttps $false
Set-Property $jellyfinConfig BaseUrl ''
Invoke-Json POST http://localhost:8096/System/Configuration/network $jHeaders $jellyfinConfig | Out-Null
$folders = Invoke-Json GET http://localhost:8096/Library/VirtualFolders $jHeaders
if (-not ($folders | Where-Object Name -eq 'Movies')) { Invoke-RestMethod 'http://localhost:8096/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fdata%2Flibrary%2Fmovies&refreshLibrary=true' -Method Post -Headers $jHeaders | Out-Null }
if (-not ($folders | Where-Object Name -eq 'Series')) { Invoke-RestMethod 'http://localhost:8096/Library/VirtualFolders?name=Series&collectionType=tvshows&paths=%2Fdata%2Flibrary%2Fseries&refreshLibrary=true' -Method Post -Headers $jHeaders | Out-Null }

function Ensure-JellyfinConnect($port, $key) {
  $base = "http://localhost:$port/api/v3"
  $headers = @{'X-Api-Key'=$key}
  $existingNotifications = @(Invoke-Json GET "$base/notification" $headers)
  $existing = $existingNotifications | Where-Object { $_.name -eq 'Media Jellyfin' } | Select-Object -First 1
  if ($null -ne $existing) { $target = $existing }
  else {
    $schemas = Invoke-Json GET "$base/notification/schema" $headers
    $target = $schemas | Where-Object implementation -eq 'MediaBrowser' | Select-Object -First 1
    if (-not $target) { throw "MediaBrowser notification schema not found on port $port" }
  }
  Set-Property $target name 'Media Jellyfin'
  if ($target.PSObject.Properties.Name -contains 'enable') { $target.enable = $true }
  foreach ($eventName in @('onDownload','onUpgrade','onRename','onMovieDelete','onSeriesDelete','onEpisodeFileDelete')) {
    if ($target.PSObject.Properties.Name -contains $eventName) { $target.$eventName = $true }
  }
  Set-Field $target host 'jellyfin'; Set-Field $target port 8096; Set-Field $target useSsl $false
  Set-Field $target apiKey $token; Set-Field $target updateLibrary $true
  if ($null -ne $existing) { Invoke-Json PUT "$base/notification/$($target.id)" $headers $target | Out-Null }
  else { Invoke-Json POST "$base/notification" $headers $target | Out-Null }
  Write-Output "Jellyfin Connect ready on port $port"
}
Write-Output 'Configuring Radarr Jellyfin Connect...'
Ensure-JellyfinConnect 7878 $radarrKey
Write-Output 'Configuring Sonarr Jellyfin Connect...'
Ensure-JellyfinConnect 8989 $sonarrKey
Write-Output 'Refreshing Jellyfin library...'
Invoke-RestMethod http://localhost:8096/Library/Refresh -Method Post -Headers $jHeaders | Out-Null

$lines = Get-Content $EnvPath
if ($lines -match '^JELLYFIN_API_KEY=') { $lines = $lines -replace '^JELLYFIN_API_KEY=.*$', "JELLYFIN_API_KEY=$token" } else { $lines += "JELLYFIN_API_KEY=$token" }
[IO.File]::WriteAllLines($EnvPath, $lines, (New-Object Text.UTF8Encoding($false)))
$composeEnvPath = Join-Path $ProjectDir '.env.compose'
if (Test-Path $composeEnvPath) {
  $composeLines = Get-Content $composeEnvPath
  if ($composeLines -match '^JELLYFIN_API_KEY=') { $composeLines = $composeLines -replace '^JELLYFIN_API_KEY=.*$', "JELLYFIN_API_KEY=$token" }
  else { $composeLines += "JELLYFIN_API_KEY=$token" }
  $freshEnv = Read-Env
  foreach ($name in @('YIFY_DIRECT_ENABLED','YIFY_DIRECT_BASE_URL','SUBTITLE_TOKEN_SECRET','YTS_OFFICIAL_TV_URL','YTS_OFFICIAL_TV_ENABLED','TV_DOWNLOAD_TOKEN_SECRET')) {
    $value = $freshEnv[$name]
    if ($composeLines -match "^$name=") { $composeLines = $composeLines -replace "^$name=.*$", "$name=$value" }
    else { $composeLines += "$name=$value" }
  }
  [IO.File]::WriteAllLines($composeEnvPath, $composeLines, (New-Object Text.UTF8Encoding($false)))
}

# Bazarr: connect Arr, then reconcile its default automatic language profile
# while the SQLite database is closed cleanly.
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
$composeEnv = Join-Path $ProjectDir '.env.compose'
docker compose --env-file $composeEnv stop bazarr | Out-Null
$openSubArgs = @()
if ($envValues.OPENSUBTITLES_USERNAME -and $envValues.OPENSUBTITLES_PASSWORD) {
  $openSubArgs = @('--opensubtitles-username', [string]$envValues.OPENSUBTITLES_USERNAME, '--opensubtitles-password', [string]$envValues.OPENSUBTITLES_PASSWORD)
}
$profileOutput = docker compose --env-file $composeEnv run --rm --no-deps --entrypoint python3 bazarr `
  /opt/media-control/bazarr_profile.py `
  --db /config/db/bazarr.db `
  --config /config/config/config.yaml `
  --backup-dir /backups/bazarr `
  --timestamp (Get-Date -Format 'yyyyMMdd-HHmmss') `
  $openSubArgs
if ($LASTEXITCODE -ne 0) { throw 'Bazarr profile reconciliation failed' }
$profileResult = $profileOutput | Select-Object -Last 1 | ConvertFrom-Json
Write-Output "Bazarr profile ready: movies=$($profileResult.moviesUpdated), series=$($profileResult.seriesUpdated)"
docker compose --env-file $composeEnv up -d bazarr | Out-Null
for ($attempt = 0; $attempt -lt 30; $attempt++) {
  try { Invoke-RestMethod http://localhost:6767/api/system/ping -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Seconds 1 }
}
$bazarrKey = ((Get-Content $bazarrPath | Select-String '^  apikey:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value)
$bHeaders = @{'X-Api-Key'=$bazarrKey}
try {
  $movies = @(Invoke-Json GET 'http://localhost:6767/api/movies?start=0&length=-1' $bHeaders).data
  foreach ($movie in $movies) { Invoke-RestMethod "http://localhost:6767/api/movies?radarrid=$($movie.radarrId)&action=sync" -Method Patch -Headers $bHeaders | Out-Null; Invoke-RestMethod "http://localhost:6767/api/movies?radarrid=$($movie.radarrId)&action=search-missing" -Method Patch -Headers $bHeaders | Out-Null }
  $series = @(Invoke-Json GET 'http://localhost:6767/api/series?start=0&length=-1' $bHeaders).data
  foreach ($show in $series) { Invoke-RestMethod "http://localhost:6767/api/series?seriesid=$($show.sonarrSeriesId)&action=sync" -Method Patch -Headers $bHeaders | Out-Null; Invoke-RestMethod "http://localhost:6767/api/series?seriesid=$($show.sonarrSeriesId)&action=search-missing" -Method Patch -Headers $bHeaders | Out-Null }
  Write-Output "Bazarr missing subtitle search queued: movies=$($movies.Count), series=$($series.Count)"
} catch { Write-Warning 'Bazarr provider unavailable; automatic retry remains scheduled.' }
docker compose --env-file (Join-Path $ProjectDir '.env.compose') up -d --force-recreate api | Out-Null

Write-Output 'Configured qBittorrent, Radarr, Sonarr, Prowlarr (YTS), Bazarr and Jellyfin.'
