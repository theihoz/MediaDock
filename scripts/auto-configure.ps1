[CmdletBinding()]
param(
  [string]$MediaRoot = 'D:\Media',
  [switch]$FirstRun
)

$ErrorActionPreference = 'Stop'
$MediaRoot = [IO.Path]::GetFullPath($MediaRoot).TrimEnd('\')
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
function Field-Value($schema, $name) {
  ($schema.fields | Where-Object name -eq $name | Select-Object -First 1).value
}
function Find-Unique($items, [scriptblock]$predicate) {
  $candidates = @($items | Where-Object -FilterScript $predicate)
  if ($candidates.Count -gt 1) { throw 'ambiguous_provider_identity: multiple resources match; rename or remove duplicates, then rerun repair.' }
  if ($candidates.Count -eq 1) { $candidates[0] }
  else { $null }
}
function Snapshot($value) { $value | ConvertTo-Json -Depth 20 -Compress }
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
  Invoke-RestMethod @args | ForEach-Object { $_ }
}

$envValues = Read-Env
$user = $envValues.LOCAL_ADMIN_USER; if (-not $user) { $user = 'admin' }
$password = $envValues.LOCAL_ADMIN_PASSWORD; if (-not $password) { $password = 'media1234' }
if (-not $envValues.YTS_MOVIE_API_URL) {
  Add-Content $EnvPath 'YTS_MOVIE_API_URL=https://movies-api.accel.li'
  $envValues.YTS_MOVIE_API_URL = 'https://movies-api.accel.li'
}
$movieApiBase = ([string]$envValues.YTS_MOVIE_API_URL).TrimEnd('/')

# Seed the protected last-good discovery cache only during bootstrap.
$trendingCache = Join-Path $MediaRoot 'cache\trending.json'
if ($FirstRun) {
  $cachedTrendingCount = 0
  if (Test-Path -LiteralPath $trendingCache) {
    try { $cachedTrendingCount = @((Get-Content $trendingCache -Raw | ConvertFrom-Json)).Count } catch {}
  }
  if ($cachedTrendingCount -lt 180) {
    try {
      $popular = Invoke-RestMethod "$movieApiBase/api/v2/list_movies.json?limit=80&sort_by=download_count" -TimeoutSec 8
      $cards = @($popular.data.movies | ForEach-Object {
        @{tmdbId=0;ytsId=[int]$_.id;mediaType='movie';title=$_.title;year=[int]$_.year;overview=$_.summary;poster=$_.medium_cover_image;runtime=$_.runtime;genres=@($_.genres);inLibrary=$false;rating=$_.rating}
      })
      if ($cards.Count -gt 0) {
        New-Item -ItemType Directory -Force -Path (Split-Path $trendingCache -Parent) | Out-Null
        [IO.File]::WriteAllText($trendingCache, ($cards | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
      }
    } catch { Write-Warning 'Could not seed trending cache; backend will retry when Discover opens.' }
  }
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

# qBittorrent: repair with the stable account; bootstrap may adopt its temporary password.
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$login = $null
try { $login = Invoke-WebRequest http://localhost:8080/api/v2/auth/login -Method Post -Body @{username=$user;password=$password} -WebSession $session -UseBasicParsing } catch {}
$loginText = if ($login -and $login.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($login.Content) } elseif ($login) { [string]$login.Content } else { '' }
if (-not $login -or -not ($login.StatusCode -eq 204 -or $loginText.Trim() -eq 'Ok.')) {
  if ($FirstRun) {
    $logs = (& cmd.exe /d /c 'docker logs media-stack-qbittorrent-1 2>&1') | Out-String
    if ($logs -notmatch 'temporary password[^:]*:\s*(\S+)') { throw 'Could not obtain qBittorrent temporary password' }
    $temporary = $matches[1]
    $login = Invoke-WebRequest http://localhost:8080/api/v2/auth/login -Method Post -Body @{username='admin';password=$temporary} -WebSession $session -UseBasicParsing
  } else { throw 'qBittorrent login failed; run repair with the configured local credentials.' }
}
$prefs = @{ save_path='/data/downloads/complete'; temp_path_enabled=$true; temp_path='/data/downloads/incomplete'; web_ui_username=$user; web_ui_password=$password }
$currentPrefs = Invoke-RestMethod http://localhost:8080/api/v2/app/preferences -WebSession $session
$preferencesDrifted = (
  $currentPrefs.save_path -ne $prefs.save_path -or
  $currentPrefs.temp_path_enabled -ne $prefs.temp_path_enabled -or
  $currentPrefs.temp_path -ne $prefs.temp_path -or
  $currentPrefs.web_ui_username -ne $prefs.web_ui_username
)
if ($FirstRun -or $preferencesDrifted) {
  Invoke-WebRequest http://localhost:8080/api/v2/app/setPreferences -Method Post -Body @{json=($prefs|ConvertTo-Json -Compress)} -WebSession $session -UseBasicParsing | Out-Null
}
$categories = Invoke-RestMethod http://localhost:8080/api/v2/torrents/categories -WebSession $session
foreach ($category in @(@{name='movies';path='/data/downloads/complete/movies'},@{name='series';path='/data/downloads/complete/series'})) {
  $property = $categories.PSObject.Properties | Where-Object Name -eq $category.name | Select-Object -First 1
  if (-not $property) {
    Invoke-WebRequest http://localhost:8080/api/v2/torrents/createCategory -Method Post -Body @{category=$category.name;savePath=$category.path} -WebSession $session -UseBasicParsing | Out-Null
  } elseif ($property.Value.savePath -ne $category.path) {
    Invoke-WebRequest http://localhost:8080/api/v2/torrents/editCategory -Method Post -Body @{category=$category.name;savePath=$category.path} -WebSession $session -UseBasicParsing | Out-Null
  }
}

function Ensure-Arr($name, $port, $key, $rootPath, $category, $categoryField) {
  $base = "http://localhost:$port/api/v3"
  $headers = @{'X-Api-Key'=$key}
  $roots = @(Invoke-Json GET "$base/rootfolder" $headers)
  $root = $roots | Where-Object path -eq $rootPath | Select-Object -First 1
  if (-not $root) { Invoke-Json POST "$base/rootfolder" $headers @{path=$rootPath} | Out-Null }
  $clients = @(Invoke-Json GET "$base/downloadclient" $headers)
  $existing = $clients | Where-Object name -eq 'Media qBittorrent' | Select-Object -First 1
  if (-not $existing) {
    $existing = Find-Unique $clients {
      ($_.implementation -eq 'QBittorrent' -or $_.implementationName -eq 'qBittorrent') -and
      (Field-Value $_ 'host') -eq 'qbittorrent'
    }
  }
  if ($existing) { $target = $existing }
  else {
    $schemas = Invoke-Json GET "$base/downloadclient/schema" $headers
    $schema = $schemas | Where-Object implementation -eq 'QBittorrent' | Select-Object -First 1
    if (-not $schema) { $schema = $schemas | Where-Object implementationName -eq 'qBittorrent' | Select-Object -First 1 }
    if (-not $schema) { throw "$name qBittorrent schema not found" }
    $target = Snapshot $schema | ConvertFrom-Json
  }
  $before = Snapshot $target
  Set-Property $target name 'Media qBittorrent'; Set-Property $target enable $true
  Set-Field $target host 'qbittorrent'; Set-Field $target port 8080; Set-Field $target username $user; Set-Field $target password $password; Set-Field $target $categoryField $category
  if ($existing) {
    if ((Snapshot $target) -ne $before) { Invoke-Json PUT "$base/downloadclient/$($target.id)" $headers $target | Out-Null }
  }
  else { Invoke-Json POST "$base/downloadclient" $headers $target | Out-Null }
}

$radarrKey = Api-Key (Join-Path $MediaRoot 'config\radarr\config.xml')
$sonarrKey = Api-Key (Join-Path $MediaRoot 'config\sonarr\config.xml')
$prowlarrKey = Api-Key (Join-Path $MediaRoot 'config\prowlarr\config.xml')
Ensure-Arr radarr 7878 $radarrKey '/data/library/movies' movies movieCategory
Ensure-Arr sonarr 8989 $sonarrKey '/data/library/series' series tvCategory

$pHeaders = @{'X-Api-Key'=$prowlarrKey}; $pBase='http://localhost:9696/api/v1'
$prowlarrChanged = $false
$existingApps = @(Invoke-Json GET "$pBase/applications" $pHeaders)
$applicationSchemas = @(Invoke-Json GET "$pBase/applications/schema" $pHeaders)
$existingIndexers = @(Invoke-Json GET "$pBase/indexer" $pHeaders)
$indexerSchemas = @(Invoke-Json GET "$pBase/indexer/schema" $pHeaders)
$appProfiles = @(Invoke-Json GET "$pBase/appprofile" $pHeaders)
$proxies = @(Invoke-Json GET "$pBase/indexerProxy" $pHeaders)
$proxySchemas = @(Invoke-Json GET "$pBase/indexerProxy/schema" $pHeaders)
foreach ($target in @(@{name='Radarr';url='http://radarr:7878';key=$radarrKey},@{name='Sonarr';url='http://sonarr:8989';key=$sonarrKey})) {
  $application = $existingApps | Where-Object name -eq $target.name | Select-Object -First 1
  if (-not $application) { $application = Find-Unique $existingApps { $_.implementation -eq $target.name } }
  if (-not $application) {
    $schema = $applicationSchemas | Where-Object implementation -eq $target.name | Select-Object -First 1
    if (-not $schema) { throw "$($target.name) application schema not found" }
    $application = Snapshot $schema | ConvertFrom-Json
  }
  $before = Snapshot $application
  Set-Property $application name $target.name; Set-Property $application enable $true
  Set-Field $application prowlarrUrl 'http://prowlarr:9696'; Set-Field $application baseUrl $target.url; Set-Field $application apiKey $target.key; Set-Field $application syncLevel 'fullSync'
  if ($application.id) {
    if ((Snapshot $application) -ne $before) { Invoke-Json PUT "$pBase/applications/$($application.id)" $pHeaders $application | Out-Null; $prowlarrChanged = $true }
  } else { Invoke-Json POST "$pBase/applications" $pHeaders $application | Out-Null; $prowlarrChanged = $true }
}

# TV searches run all configured providers concurrently. Enable the public
# source here; backend deadlines ensure it cannot block successful providers.
$tags = @(Invoke-Json GET "$pBase/tag" $pHeaders)
$flareTag = Find-Item $tags 'label' 'flaresolverr'
if (-not $flareTag) { $flareTag = Invoke-Json POST "$pBase/tag" $pHeaders @{label='flaresolverr'}; $prowlarrChanged = $true }
$nyaaTag = Find-Item $tags 'label' 'nyaa-anime'
if (-not $nyaaTag) { $nyaaTag = Invoke-Json POST "$pBase/tag" $pHeaders @{label='nyaa-anime'}; $prowlarrChanged = $true }
$proxy = $proxies | Where-Object { $_.name -eq 'Media FlareSolverr' } | Select-Object -First 1
if (-not $proxy) { $proxy = Find-Unique $proxies { $_.implementation -eq 'FlareSolverr' } }
if (-not $proxy) {
  $schema = $proxySchemas | Where-Object implementation -eq 'FlareSolverr' | Select-Object -First 1
  if ($schema) { $proxy = Snapshot $schema | ConvertFrom-Json }
}
if (-not $proxy) { throw 'FlareSolverr proxy schema not found' }
$before = Snapshot $proxy
Set-Property $proxy name 'Media FlareSolverr'; Set-Property $proxy tags @($flareTag.id)
Set-Field $proxy host 'http://flaresolverr:8191/'
if ($proxy.id) {
  if ((Snapshot $proxy) -ne $before) { Invoke-Json PUT "$pBase/indexerProxy/$($proxy.id)" $pHeaders $proxy | Out-Null; $prowlarrChanged = $true }
} else { Invoke-Json POST "$pBase/indexerProxy" $pHeaders $proxy | Out-Null; $prowlarrChanged = $true }

function Ensure-NyaaIndexer($name, $baseUrl, $useFlareSolverr) {
  $existing = Find-Item $existingIndexers 'name' $name
  if (-not $existing) {
    $existing = Find-Unique $existingIndexers { ([string](Field-Value $_ 'baseUrl')).TrimEnd('/') -eq $baseUrl.TrimEnd('/') }
  }
  if ($existing) {
    $target = $existing
  } else {
    $schema = Find-Item $indexerSchemas 'name' 'Nyaa.si'
    if (-not $schema) { $schema = Find-Item $indexerSchemas 'name' 'Nyaa' }
    if (-not $schema) {
      Write-Warning "$name`: needs_manual_configuration (Nyaa schema unavailable)"
      return
    }
    $target = $schema | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  }
  $before = Snapshot $target
  Set-Property $target name $name
  Set-Property $target enable $true
  if ($appProfiles.Count -gt 0) { Set-Property $target appProfileId $appProfiles[0].id }
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
  if ($existing) {
    if ((Snapshot $target) -ne $before) { Invoke-Json PUT "$pBase/indexer/$($target.id)?forceSave=true" $pHeaders $target | Out-Null; $script:prowlarrChanged = $true }
  } else {
    Add-DisabledIndexer $target
  }
}

function Add-DisabledIndexer($target) {
  Set-Property $target enable $false
  $created = Invoke-Json POST "$pBase/indexer?forceSave=true" $pHeaders $target
  Set-Property $created enable $true
  Invoke-Json PUT "$pBase/indexer/$($created.id)?forceSave=true" $pHeaders $created | Out-Null
  $script:prowlarrChanged = $true
}

Ensure-NyaaIndexer 'Nyaa.si' 'https://nyaa.si/' $true
Ensure-NyaaIndexer 'Nyaa.land' 'https://nyaa.land/' $true

$archive = $existingIndexers | Where-Object name -eq 'Internet Archive' | Select-Object -First 1
if (-not $archive) { $archive = Find-Unique $existingIndexers { $_.implementation -eq 'InternetArchive' } }
if ($archive -and -not $archive.enable) {
  Set-Property $archive enable $true
  Invoke-Json PUT "$pBase/indexer/$($archive.id)?forceSave=true" $pHeaders $archive | Out-Null
  $prowlarrChanged = $true
}

# Prowlarr currently has no built-in Public Domain Torrents definition and the
# site does not expose a compatible Torznab/RSS feed. Keep this visible as an
# explicit manual-feed state rather than adding a fragile scraper.
$publicDomainSchema = $indexerSchemas | Where-Object { $_.name -eq 'Public Domain Torrents' } | Select-Object -First 1
if (-not $publicDomainSchema) { Write-Warning 'Public Domain Torrents: needs_manual_feed (no compatible Prowlarr schema)' }

# YTS is explicitly requested for authorized/local use. Its API does not
# reliably publish seed counts, so set the per-indexer application minimum to
# zero; otherwise Radarr rejects every returned release as "0 seeders".
$yts = $existingIndexers | Where-Object name -eq 'YTS' | Select-Object -First 1
if (-not $yts) {
  $yts = Find-Unique $existingIndexers {
    $_.implementation -eq 'YTS' -or ([string](Field-Value $_ 'baseUrl')).TrimEnd('/') -eq 'https://yts.gg'
  }
}
if (-not $yts) {
  $schema = $indexerSchemas | Where-Object name -eq 'YTS' | Select-Object -First 1
  if ($schema) { $yts = Snapshot $schema | ConvertFrom-Json }
}
if ($yts) {
  $before = Snapshot $yts
  Set-Property $yts name 'YTS'; Set-Property $yts enable $true
  Set-Property $yts appProfileId $appProfiles[0].id
  Set-Field $yts baseUrl 'https://yts.gg/'
  Set-Field $yts apiurl 'movies-api.accel.li'
  Set-Field $yts 'torrentBaseSettings.appMinimumSeeders' 0
  if ($yts.id) {
    if ((Snapshot $yts) -ne $before) { Invoke-Json PUT "$pBase/indexer/$($yts.id)?forceSave=true" $pHeaders $yts | Out-Null; $prowlarrChanged = $true }
  } else { Add-DisabledIndexer $yts }
}

# EZTV is the first Sonarr/Prowlarr fallback when YTS has no exact TV release.
$existingEztv = $existingIndexers | Where-Object { $_.name -eq 'EZTV' } | Select-Object -First 1
if (-not $existingEztv) {
  $existingEztv = Find-Unique $existingIndexers {
    $_.implementation -eq 'EZTV' -or ([string](Field-Value $_ 'baseUrl')).TrimEnd('/') -eq 'https://eztvx.to'
  }
}
$eztv = $existingEztv
if (-not $existingEztv) {
  $schema = $indexerSchemas | Where-Object name -eq 'EZTV' | Select-Object -First 1
  if ($schema) { $eztv = Snapshot $schema | ConvertFrom-Json }
}
if ($eztv) {
  $before = Snapshot $eztv
  Set-Property $eztv name 'EZTV'; Set-Property $eztv enable $true
  Set-Property $eztv tags @($flareTag.id)
  Set-Property $eztv appProfileId $appProfiles[0].id
  Set-Field $eztv baseUrl 'https://eztvx.to/'
  if ($existingEztv) {
    if ((Snapshot $eztv) -ne $before) { Invoke-Json PUT "$pBase/indexer/$($eztv.id)?forceSave=true" $pHeaders $eztv | Out-Null; $prowlarrChanged = $true }
  } else { Add-DisabledIndexer $eztv }
}

# Fourth TV source, especially useful for anime where EZTV coverage is sparse.
# Tokyo Toshokan is used because it is reachable without credentials on this network.
$existingTokyo = $existingIndexers | Where-Object { $_.name -eq 'Tokyo Toshokan' } | Select-Object -First 1
if (-not $existingTokyo) {
  $existingTokyo = Find-Unique $existingIndexers { ([string](Field-Value $_ 'baseUrl')).TrimEnd('/') -eq 'https://www.tokyotosho.info' }
}
$tokyo = $existingTokyo
if (-not $existingTokyo) {
  $schema = $indexerSchemas | Where-Object name -eq 'Tokyo Toshokan' | Select-Object -First 1
  if ($schema) { $tokyo = Snapshot $schema | ConvertFrom-Json }
}
if ($tokyo) {
  $before = Snapshot $tokyo
  Set-Property $tokyo name 'Tokyo Toshokan'; Set-Property $tokyo enable $true
  Set-Property $tokyo appProfileId $appProfiles[0].id
  Set-Field $tokyo baseUrl 'https://www.tokyotosho.info/'
  if ($existingTokyo) {
    if ((Snapshot $tokyo) -ne $before) { Invoke-Json PUT "$pBase/indexer/$($tokyo.id)?forceSave=true" $pHeaders $tokyo | Out-Null; $prowlarrChanged = $true }
  } else { Add-DisabledIndexer $tokyo }
}

foreach ($profile in $appProfiles) {
  if ($profile.minimumSeeders -ne 0) {
    $profile.minimumSeeders = 0
    Invoke-Json PUT "$pBase/appprofile/$($profile.id)" $pHeaders $profile | Out-Null
    $prowlarrChanged = $true
  }
}
if ($prowlarrChanged) { Invoke-Json POST "$pBase/command" $pHeaders @{name='ApplicationIndexerSync'} | Out-Null }

# Jellyfin first-run wizard and API token for the gateway.
$public = Invoke-RestMethod http://localhost:8096/System/Info/Public
if ($FirstRun -and -not $public.StartupWizardCompleted) {
  Invoke-Json POST http://localhost:8096/Startup/Configuration @{} @{UICulture='en-US';MetadataCountryCode='US';PreferredMetadataLanguage='en'} | Out-Null
  Invoke-Json POST http://localhost:8096/Startup/User @{} @{Name=$user;Password=$password} | Out-Null
  Invoke-Json POST http://localhost:8096/Startup/RemoteAccess @{} @{EnableRemoteAccess=$true;EnableAutomaticPortMapping=$false} | Out-Null
  Invoke-Json POST http://localhost:8096/Startup/Complete @{} @{} | Out-Null
}
$token = $envValues.JELLYFIN_API_KEY
$jHeaders = @{}
if ($token) {
  $jHeaders = @{'X-Emby-Token'=$token}
  try { Invoke-RestMethod http://localhost:8096/System/Info -Headers $jHeaders -TimeoutSec 5 | Out-Null }
  catch { $token = $null }
}
if (-not $token) {
  $authHeader = @{Authorization='MediaBrowser Client="MediaControl", Device="Windows", DeviceId="media-control-local", Version="1.0"'}
  $auth = Invoke-Json POST http://localhost:8096/Users/AuthenticateByName $authHeader @{Username=$user;Pw=$password}
  $token = $auth.AccessToken
  $jHeaders = @{'X-Emby-Token'=$token}
}
Write-Output 'Configuring Jellyfin LAN access...'
$jellyfinConfig = Invoke-Json GET http://localhost:8096/System/Configuration/network $jHeaders
$before = Snapshot $jellyfinConfig
Set-Property $jellyfinConfig EnableRemoteAccess $true
Set-Property $jellyfinConfig EnableUPnP $false
Set-Property $jellyfinConfig EnableHttps $false
Set-Property $jellyfinConfig BaseUrl ''
if ((Snapshot $jellyfinConfig) -ne $before) { Invoke-Json POST http://localhost:8096/System/Configuration/network $jHeaders $jellyfinConfig | Out-Null }
$folders = Invoke-Json GET http://localhost:8096/Library/VirtualFolders $jHeaders
$jellyfinLibraryChanged = $false
function Ensure-JellyfinLibrary($name, $collectionType, $path) {
  $folder = $folders | Where-Object Name -eq $name | Select-Object -First 1
  if (-not $folder) { $folder = Find-Unique $folders { $_.CollectionType -eq $collectionType } }
  $encodedName = [Uri]::EscapeDataString($name)
  if (-not $folder) {
    $encodedPath = [Uri]::EscapeDataString($path)
    Invoke-RestMethod "http://localhost:8096/Library/VirtualFolders?name=$encodedName&collectionType=$collectionType&paths=$encodedPath&refreshLibrary=true" -Method Post -Headers $jHeaders | Out-Null
    $script:jellyfinLibraryChanged = $true
    return
  }
  $locations = @($folder.Locations)
  if ($locations.Count -ne 1 -or $locations -notcontains $path) {
    Invoke-Json POST http://localhost:8096/Library/VirtualFolders/Paths/Update $jHeaders @{Name=$folder.Name;PathInfo=@{Path=$path}} | Out-Null
    $script:jellyfinLibraryChanged = $true
  }
}
Ensure-JellyfinLibrary Movies movies '/data/library/movies'
Ensure-JellyfinLibrary Series tvshows '/data/library/series'

function Ensure-JellyfinConnect($port, $key) {
  $base = "http://localhost:$port/api/v3"
  $headers = @{'X-Api-Key'=$key}
  $existingNotifications = @(Invoke-Json GET "$base/notification" $headers)
  $existing = $existingNotifications | Where-Object { $_.name -eq 'Media Jellyfin' } | Select-Object -First 1
  if (-not $existing) { $existing = Find-Unique $existingNotifications { $_.implementation -eq 'MediaBrowser' } }
  if ($null -ne $existing) { $target = $existing }
  else {
    $schemas = Invoke-Json GET "$base/notification/schema" $headers
    $target = $schemas | Where-Object implementation -eq 'MediaBrowser' | Select-Object -First 1
    if (-not $target) { throw "MediaBrowser notification schema not found on port $port" }
  }
  $before = Snapshot $target
  Set-Property $target name 'Media Jellyfin'
  if ($target.PSObject.Properties.Name -contains 'enable') { $target.enable = $true }
  foreach ($eventName in @('onDownload','onUpgrade','onRename','onMovieDelete','onSeriesDelete','onEpisodeFileDelete')) {
    if ($target.PSObject.Properties.Name -contains $eventName) { $target.$eventName = $true }
  }
  Set-Field $target host 'jellyfin'; Set-Field $target port 8096; Set-Field $target useSsl $false
  Set-Field $target apiKey $token; Set-Field $target updateLibrary $true
  if ($null -ne $existing) {
    if ((Snapshot $target) -ne $before) { Invoke-Json PUT "$base/notification/$($target.id)" $headers $target | Out-Null }
  }
  else { Invoke-Json POST "$base/notification" $headers $target | Out-Null }
  Write-Output "Jellyfin Connect ready on port $port"
}
Write-Output 'Configuring Radarr Jellyfin Connect...'
Ensure-JellyfinConnect 7878 $radarrKey
Write-Output 'Configuring Sonarr Jellyfin Connect...'
Ensure-JellyfinConnect 8989 $sonarrKey
if ($FirstRun -or $jellyfinLibraryChanged) {
  Write-Output 'Refreshing Jellyfin library...'
  Invoke-RestMethod http://localhost:8096/Library/Refresh -Method Post -Headers $jHeaders | Out-Null
}

$envOriginal = @(Get-Content $EnvPath)
$lines = @($envOriginal)
if ($lines -match '^JELLYFIN_API_KEY=') { $lines = $lines -replace '^JELLYFIN_API_KEY=.*$', "JELLYFIN_API_KEY=$token" } else { $lines += "JELLYFIN_API_KEY=$token" }
if ([string]::Join("`n", $envOriginal) -ne [string]::Join("`n", $lines)) {
  [IO.File]::WriteAllLines($EnvPath, $lines, (New-Object Text.UTF8Encoding($false)))
}
$composeEnvPath = Join-Path $ProjectDir '.env.compose'
$composeEnvChanged = $false
if (Test-Path $composeEnvPath) {
  $composeOriginal = @(Get-Content $composeEnvPath)
  $composeLines = @($composeOriginal)
  if ($composeLines -match '^JELLYFIN_API_KEY=') { $composeLines = $composeLines -replace '^JELLYFIN_API_KEY=.*$', "JELLYFIN_API_KEY=$token" }
  else { $composeLines += "JELLYFIN_API_KEY=$token" }
  $freshEnv = Read-Env
  foreach ($name in @('YTS_MOVIE_API_URL','YIFY_DIRECT_ENABLED','YIFY_DIRECT_BASE_URL','SUBTITLE_TOKEN_SECRET','YTS_OFFICIAL_TV_URL','YTS_OFFICIAL_TV_ENABLED','TV_DOWNLOAD_TOKEN_SECRET')) {
    $value = $freshEnv[$name]
    if ($composeLines -match "^$name=") { $composeLines = $composeLines -replace "^$name=.*$", "$name=$value" }
    else { $composeLines += "$name=$value" }
  }
  $composeEnvChanged = [string]::Join("`n", $composeOriginal) -ne [string]::Join("`n", $composeLines)
  if ($composeEnvChanged) { [IO.File]::WriteAllLines($composeEnvPath, $composeLines, (New-Object Text.UTF8Encoding($false))) }
}

# Bazarr: connect Arr, then reconcile its default automatic language profile
# while the SQLite database is closed cleanly.
$bazarrPath = Join-Path $MediaRoot 'config\bazarr\config\config.yaml'
$bazarrOriginal = [IO.File]::ReadAllLines($bazarrPath)
$bazarrDesired = @{
  general = [ordered]@{ use_radarr='true'; use_sonarr='true' }
  radarr = [ordered]@{ apikey=$radarrKey; ip='radarr' }
  sonarr = [ordered]@{ apikey=$sonarrKey; ip='sonarr' }
}
$section = ''
$bazarrSections = @{}
$bazarrSeen = @{}
$bazarrLines = New-Object Collections.Generic.List[string]
function Add-MissingBazarrKeys($name) {
  if (-not $bazarrDesired.ContainsKey($name)) { return }
  foreach ($keyName in $bazarrDesired[$name].Keys) {
    $identity = "$name.$keyName"
    if (-not $bazarrSeen.ContainsKey($identity)) {
      $bazarrLines.Add("  ${keyName}: $($bazarrDesired[$name][$keyName])")
      $bazarrSeen[$identity] = $true
    }
  }
}
foreach ($line in $bazarrOriginal) {
  if ($line -match '^([a-zA-Z][a-zA-Z0-9_]*):\s*$') {
    Add-MissingBazarrKeys $section
    $section = $matches[1]
    $bazarrSections[$section] = $true
    $bazarrLines.Add($line)
    continue
  }
  if ($bazarrDesired.ContainsKey($section) -and $line -match '^  ([a-zA-Z][a-zA-Z0-9_]*):') {
    $keyName = $matches[1]
    if ($bazarrDesired[$section].Contains($keyName)) {
      $bazarrLines.Add("  ${keyName}: $($bazarrDesired[$section][$keyName])")
      $bazarrSeen["$section.$keyName"] = $true
      continue
    }
  }
  $bazarrLines.Add($line)
}
Add-MissingBazarrKeys $section
foreach ($sectionName in $bazarrDesired.Keys) {
  if (-not $bazarrSections.ContainsKey($sectionName)) {
    if ($bazarrLines.Count -gt 0 -and $bazarrLines[$bazarrLines.Count - 1]) { $bazarrLines.Add('') }
    $bazarrLines.Add("${sectionName}:")
    Add-MissingBazarrKeys $sectionName
  }
}
$bazarrYamlChanged = ([string]::Join("`n", $bazarrOriginal) -ne [string]::Join("`n", $bazarrLines))
if ($bazarrYamlChanged) { [IO.File]::WriteAllLines($bazarrPath, $bazarrLines, (New-Object Text.UTF8Encoding($false))) }
$composeEnv = Join-Path $ProjectDir '.env.compose'
docker compose --env-file $composeEnv stop bazarr | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Bazarr stop failed; database reconciliation was not started.' }
$openSubArgs = @()
if ($envValues.OPENSUBTITLES_USERNAME -and $envValues.OPENSUBTITLES_PASSWORD) {
  $openSubArgs = @('--opensubtitles-username', [string]$envValues.OPENSUBTITLES_USERNAME, '--opensubtitles-password', [string]$envValues.OPENSUBTITLES_PASSWORD)
}
$profileResult = $null
$profileError = $null
$bazarrRestartExitCode = 0
try {
  $profileOutput = docker compose --env-file $composeEnv run --rm --no-deps --entrypoint python3 bazarr `
    /opt/media-control/bazarr_profile.py `
    --db /config/db/bazarr.db `
    --config /config/config/config.yaml `
    --backup-dir /backups/bazarr `
    --timestamp (Get-Date -Format 'yyyyMMdd-HHmmss') `
    $openSubArgs
  if ($LASTEXITCODE -ne 0) { throw 'Bazarr profile reconciliation failed' }
  $profileResult = $profileOutput | Select-Object -Last 1 | ConvertFrom-Json
} catch { $profileError = $_ }
finally {
  docker compose --env-file $composeEnv up -d bazarr | Out-Null
  $bazarrRestartExitCode = $LASTEXITCODE
}
if ($profileError) { throw $profileError }
if ($bazarrRestartExitCode -ne 0) { throw 'Bazarr restart failed; repair stopped before reporting success.' }
Write-Output "Bazarr profile ready: movies=$($profileResult.moviesUpdated), series=$($profileResult.seriesUpdated)"
$bazarrReady = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
  try { Invoke-RestMethod http://localhost:6767/api/system/ping -TimeoutSec 2 | Out-Null; $bazarrReady = $true; break } catch { Start-Sleep -Seconds 1 }
}
if (-not $bazarrReady) { throw 'bazarr_readiness_timeout: Bazarr did not respond after restart; inspect docker compose logs bazarr.' }
$bazarrKey = ((Get-Content $bazarrPath | Select-String '^  apikey:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value)
$bHeaders = @{'X-Api-Key'=$bazarrKey}
$bazarrChanged = $bazarrYamlChanged -or $profileResult.moviesUpdated -gt 0 -or $profileResult.seriesUpdated -gt 0
try {
  $movies = @()
  $series = @()
  if ($bazarrChanged -or $FirstRun) {
    $movies = @(Invoke-Json GET 'http://localhost:6767/api/movies?start=0&length=-1' $bHeaders).data
    $series = @(Invoke-Json GET 'http://localhost:6767/api/series?start=0&length=-1' $bHeaders).data
  }
  if ($bazarrChanged) {
    foreach ($movie in $movies) { Invoke-RestMethod "http://localhost:6767/api/movies?radarrid=$($movie.radarrId)&action=sync" -Method Patch -Headers $bHeaders | Out-Null }
    foreach ($show in $series) { Invoke-RestMethod "http://localhost:6767/api/series?seriesid=$($show.sonarrSeriesId)&action=sync" -Method Patch -Headers $bHeaders | Out-Null }
  }
  if ($FirstRun) {
    foreach ($movie in $movies) { Invoke-RestMethod "http://localhost:6767/api/movies?radarrid=$($movie.radarrId)&action=search-missing" -Method Patch -Headers $bHeaders | Out-Null }
    foreach ($show in $series) { Invoke-RestMethod "http://localhost:6767/api/series?seriesid=$($show.sonarrSeriesId)&action=search-missing" -Method Patch -Headers $bHeaders | Out-Null }
    Write-Output "Bazarr missing subtitle search queued: movies=$($movies.Count), series=$($series.Count)"
  }
} catch { Write-Warning 'Bazarr provider unavailable; automatic retry remains scheduled.' }
if ($composeEnvChanged) {
  docker compose --env-file (Join-Path $ProjectDir '.env.compose') up -d --force-recreate api | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'gateway_restart_failed: API container could not be recreated; inspect docker compose logs api.' }
}

Write-Output 'Configured qBittorrent, Radarr, Sonarr, Prowlarr (YTS), Bazarr and Jellyfin.'
