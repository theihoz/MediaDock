import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';

test('bootstrap enables Internet Archive as an independent public TV source', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Where-Object name -eq 'Internet Archive'/);
  assert.match(script, /Set-Property \$archive enable \$true/);
  assert.match(script, /Where-Object name -eq 'YTS'[\s\S]+Set-Property \$yts enable \$true/);
});

test('bootstrap enables Tokyo Toshokan idempotently as the fourth TV source', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Where-Object \{ \$_\.name -eq 'Tokyo Toshokan' \}/);
  assert.match(script, /Set-Property \$tokyo name 'Tokyo Toshokan'/);
  assert.match(script, /Set-Property \$tokyo enable \$true/);
  assert.match(script, /Set-Field \$tokyo baseUrl 'https:\/\/www\.tokyotosho\.info\/'/);
});

test('bootstrap reconciles both Nyaa endpoints through FlareSolverr', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Ensure-NyaaIndexer 'Nyaa\.si' 'https:\/\/nyaa\.si\/'/);
  assert.match(script, /Ensure-NyaaIndexer 'Nyaa\.land' 'https:\/\/nyaa\.land\/' \$true/);
  assert.match(script, /Set-Property \$target tags @\(\$flareTag\.id, \$nyaaTag\.id\)/);
  assert.match(script, /Set-Field \$target sonarr_compatibility \$true/);
  assert.match(script, /Set-Field \$target radarr_compatibility \$true/);
  assert.match(script, /if \(\$existing\)[\s\S]+Invoke-Json PUT "\$pBase\/indexer\/\$\(\$target\.id\)\?forceSave=true"/);
  assert.match(script, /needs_manual_configuration \(baseUrl is not editable\)/);
});

test('new external indexers are created disabled before test-free enable updates', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  const start = script.indexOf('function Ensure-NyaaIndexer');
  const block = script.slice(start, script.indexOf('foreach ($profile', start));
  const command = `
    function Find-Item($items, $property, $value) { $items | Where-Object { $_.$property -eq $value } | Select-Object -First 1 }
    function Find-Unique { $null }
    function Field-Value($schema, $name) { ($schema.fields | Where-Object name -eq $name | Select-Object -First 1).value }
    function Snapshot($value) { $value | ConvertTo-Json -Depth 20 -Compress }
    function Set-Property($object, $name, $value) { $object | Add-Member -Force -NotePropertyName $name -NotePropertyValue $value }
    function Set-Field($schema, $name, $value) { $field = $schema.fields | Where-Object name -eq $name | Select-Object -First 1; if ($field) { $field.value = $value } }
    $calls = [Collections.Generic.List[object]]::new(); $script:nextId = 40
    function Invoke-Json($method, $uri, $headers, $body) {
      $calls.Add([pscustomobject]@{ method=$method; uri=$uri; name=[string]$body.name; enable=[bool]$body.enable }) | Out-Null
      if ($method -eq 'POST') { $script:nextId++; $body | Add-Member -Force -NotePropertyName id -NotePropertyValue $script:nextId }
      $body
    }
    $existingIndexers = @()
    $indexerSchemas = @(
      [pscustomobject]@{ name='Nyaa.si'; enable=$true; fields=@([pscustomobject]@{ name='baseUrl'; value='' }) },
      [pscustomobject]@{ name='YTS'; enable=$true; fields=@([pscustomobject]@{ name='baseUrl'; value='' }) },
      [pscustomobject]@{ name='EZTV'; enable=$true; fields=@([pscustomobject]@{ name='baseUrl'; value='' }) },
      [pscustomobject]@{ name='Tokyo Toshokan'; enable=$true; fields=@([pscustomobject]@{ name='baseUrl'; value='' }) }
    )
    $appProfiles = @([pscustomobject]@{ id=1 }); $flareTag = [pscustomobject]@{ id=2 }; $nyaaTag = [pscustomobject]@{ id=3 }
    $pBase = 'http://prowlarr/api/v1'; $pHeaders = @{}
    ${block}
    foreach ($name in @('Nyaa.si', 'Nyaa.land', 'YTS', 'EZTV', 'Tokyo Toshokan')) {
      $resourceCalls = @($calls | Where-Object name -eq $name)
      if ($resourceCalls.Count -ne 2) { throw "expected_post_then_put:$($name):$($resourceCalls.Count)" }
      if ($resourceCalls[0].method -ne 'POST' -or $resourceCalls[0].enable -or $resourceCalls[0].uri -notmatch '/indexer\\?forceSave=true$') { throw "expected_disabled_post:$name" }
      if ($resourceCalls[1].method -ne 'PUT' -or -not $resourceCalls[1].enable -or $resourceCalls[1].uri -notmatch '/indexer/\\d+\\?forceSave=true$') { throw "expected_enabled_put:$name" }
    }
  `;
  const result = spawnSync('powershell.exe', [
    '-NoProfile', '-EncodedCommand', Buffer.from(command, 'utf16le').toString('base64'),
  ], { encoding: 'utf8' });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

test('bootstrap reports Public Domain Torrents as requiring a manual compatible feed when Prowlarr has no schema', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Public Domain Torrents/);
  assert.match(script, /needs_manual_feed/);
});

test('bootstrap updates existing PowerShell object properties without duplicate Add-Member failures', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Add-Member -Force -NotePropertyName \$name -NotePropertyValue \$value/);
});

test('Invoke-Json enumerates provider JSON arrays for callers', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  const start = script.indexOf('function Invoke-Json');
  const helper = script.slice(start, script.indexOf('$envValues', start));
  const command = `${helper}
    function Invoke-RestMethod { ,@([pscustomobject]@{path='a'},[pscustomobject]@{path='b'}) }
    $items = @(Invoke-Json GET x @{})
    if ($items.Count -ne 2) { throw "expected_two_items:$($items.Count)" }
    if (@($items | Where-Object path -eq 'a').Count -ne 1) { throw 'expected_path_lookup' }
  `;
  const result = spawnSync('powershell.exe', [
    '-NoProfile', '-EncodedCommand', Buffer.from(command, 'utf16le').toString('base64'),
  ], { encoding: 'utf8' });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

test('bootstrap enables EZTV idempotently as the TV fallback', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Where-Object name -eq 'EZTV'/);
  assert.match(script, /Where-Object \{ \$_\.name -eq 'EZTV' \} \| Select-Object -First 1/);
  assert.match(script, /Set-Property \$eztv name 'EZTV'/);
  assert.match(script, /Set-Property \$eztv enable \$true/);
  assert.match(script, /Set-Field \$eztv baseUrl 'https:\/\/eztvx\.to\/'/);
  assert.match(script, /implementation -eq 'FlareSolverr'/);
  assert.match(script, /Set-Field \$proxy host 'http:\/\/flaresolverr:8191\/'/);
  assert.match(script, /Set-Property \$eztv tags @\(\$flareTag\.id\)/);
  assert.match(script, /ApplicationIndexerSync/);
});

test('compose exposes YTS Official TV settings only to the API and keeps manual restart policy', () => {
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  assert.match(compose, /api:[\s\S]+YTS_OFFICIAL_TV_URL: \$\{YTS_OFFICIAL_TV_URL:-https:\/\/en\.yts-official\.com\/\}/);
  assert.match(compose, /api:[\s\S]+YTS_OFFICIAL_TV_ENABLED: \$\{YTS_OFFICIAL_TV_ENABLED:-true\}/);
  assert.match(compose, /api:[\s\S]+TV_DOWNLOAD_TOKEN_SECRET: \$\{TV_DOWNLOAD_TOKEN_SECRET\}/);
  assert.match(compose, /api:\s*\n\s+build: \.\/backend\s*\n\s+restart: "no"/);
});

test('API mounts Arr configuration directories so Docker Desktop does not turn config files into empty folders', () => {
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  assert.match(compose, /RADARR_CONFIG: \/service-config\/radarr\/config\.xml/);
  assert.match(compose, /SONARR_CONFIG: \/service-config\/sonarr\/config\.xml/);
  assert.match(compose, /PROWLARR_CONFIG: \/service-config\/prowlarr\/config\.xml/);
  assert.match(compose, /\$\{MEDIA_ROOT_DOCKER:-D:\/Media\}\/config\/radarr:\/service-config\/radarr:ro/);
  assert.match(compose, /\$\{MEDIA_ROOT_DOCKER:-D:\/Media\}\/config\/sonarr:\/service-config\/sonarr:ro/);
  assert.match(compose, /\$\{MEDIA_ROOT_DOCKER:-D:\/Media\}\/config\/prowlarr:\/service-config\/prowlarr:ro/);
});

test('bootstrap seeds the protected trending cache from YTS when missing', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /trending\.json/);
  assert.match(script, /list_movies\.json\?limit=80&sort_by=download_count/);
  assert.match(script, /\$cachedTrendingCount -lt 180/);
});

test('compose bounds Docker stdout logs for every service group', () => {
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  assert.match(compose, /x-logging: &logging[\s\S]+driver: local[\s\S]+max-size: "10m"[\s\S]+max-file: "2"/);
  assert.equal((compose.match(/logging: \*logging/g) ?? []).length, 2);
});

test('bootstrap configures Arr to notify Jellyfin and refreshes the library', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /implementation -eq 'MediaBrowser'/);
  assert.match(script, /Set-Field \$target host 'jellyfin'/);
  assert.match(script, /Set-Field \$target updateLibrary \$true/);
  assert.match(script, /if \(\$null -ne \$existing\)[\s\S]+Invoke-Json PUT "\$base\/notification\/\$\(\$target\.id\)"/);
  assert.doesNotMatch(script, /if \(\$null -ne \$existing\) \{ return \}/);
  assert.match(script, /Library\/Refresh/);
  assert.match(script, /EnableRemoteAccess \$true/);
  assert.match(script, /EnableUPnP \$false/);
  assert.match(script, /BaseUrl ''/);
  const reuse = script.indexOf('$token = $envValues.JELLYFIN_API_KEY');
  const authenticate = script.indexOf('/Users/AuthenticateByName');
  assert.ok(reuse >= 0 && reuse < authenticate);
  assert.match(script, /System\/Info -Headers \$jHeaders -TimeoutSec 5/);
  assert.match(script, /if \(-not \$token\) \{[\s\S]+Users\/AuthenticateByName/);
});

test('bootstrap safely reconciles the automatic Vietnamese-English Bazarr profile', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  assert.match(script, /docker compose[\s\S]+stop bazarr/);
  assert.match(script, /docker compose[\s\S]+run --rm --no-deps --entrypoint python3 bazarr/);
  assert.doesNotMatch(script, /Get-Command python|codex-runtimes/);
  assert.match(compose, /bazarr:[\s\S]+bazarr_profile\.py:\/opt\/media-control\/bazarr_profile\.py:ro/);
  assert.match(compose, /bazarr:[\s\S]+\/backups/);
  assert.match(script, /docker compose[\s\S]+up -d bazarr/);
  assert.match(script, /action=sync/);
  assert.match(script, /action=search-missing/);
  assert.match(script, /Bazarr profile ready/);
  assert.match(script, /--opensubtitles-username/);
  assert.match(script, /--opensubtitles-password/);
  assert.match(script, /OPENSUBTITLES_USERNAME/);
  assert.match(script, /OPENSUBTITLES_PASSWORD/);
  assert.doesNotMatch(script, /Write-Output[^\n]*OPENSUBTITLES_(?:USERNAME|PASSWORD)/);
});

test('Samsung LAN setup publishes discovery and creates private firewall rules', () => {
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  const install = fs.readFileSync(new URL('../../scripts/install-host-controller.ps1', import.meta.url), 'utf8');
  assert.match(compose, /7359:7359\/udp/);
  assert.match(install, /New-NetFirewallRule[\s\S]+Profile Private[\s\S]+RemoteAddress LocalSubnet/);
  assert.doesNotMatch(install, /portproxy|UPnP|router/i);
});

test('provider reconciliation accepts a custom media root and gates first-run-only work', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  const executable = script.indexOf('$ErrorActionPreference');
  assert.match(script.slice(0, executable), /^\[CmdletBinding\(\)\][\s\S]+\[string\]\$MediaRoot\s*=\s*'D:\\Media'[\s\S]+\[switch\]\$FirstRun/);
  assert.equal((script.match(/D:\\Media/g) ?? []).length, 1);
  assert.match(script, /Join-Path \$MediaRoot 'cache\\trending\.json'/);
  assert.match(script, /Join-Path \$MediaRoot 'config\\radarr\\config\.xml'/);
  assert.match(script, /Join-Path \$MediaRoot 'config\\bazarr\\config\\config\.yaml'/);
  assert.match(script, /\$movieApiBase = \(\[string\]\$envValues\.YTS_MOVIE_API_URL\)\.TrimEnd/);
  assert.match(script, /Invoke-RestMethod "\$movieApiBase\/api\/v2\/list_movies\.json\?limit=80&sort_by=download_count"/);
  assert.match(script, /if \(\$FirstRun\)[\s\S]+list_movies\.json\?limit=80&sort_by=download_count/);
  assert.match(script, /if \(\$FirstRun\) \{[\s\S]{0,500}docker logs media-stack-qbittorrent-1/);
  assert.match(script, /if \(\$FirstRun -or \$preferencesDrifted\)/);
  assert.match(script, /if \(\$FirstRun -and -not \$public\.StartupWizardCompleted\)/);
  const bazarrSync = script.indexOf('$movies = @(Invoke-Json GET');
  const batchStart = script.indexOf('if ($FirstRun) {', bazarrSync);
  const batchEnd = script.indexOf('\n  }\n} catch', batchStart);
  const firstRunBatch = script.slice(batchStart, batchEnd);
  assert.equal((firstRunBatch.match(/action=search-missing/g) ?? []).length, 2);
  assert.doesNotMatch(script.slice(0, batchStart) + script.slice(batchEnd), /action=search-missing/);
});

test('Bazarr Python is the only owner of subtitle providers and first-run batches', () => {
  const powershell = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  const python = fs.readFileSync(new URL('../../scripts/bazarr_profile.py', import.meta.url), 'utf8');
  assert.doesNotMatch(powershell, /enabled_providers/);
  assert.match(python, /enabled_providers/);
  assert.match(python, /opensubtitles/i);
  assert.equal((powershell.match(/ApplicationIndexerSync/g) ?? []).length, 1);
});

test('provider reconciliation updates drifted resources instead of creating duplicates', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /torrents\/editCategory/);
  assert.match(script, /if \(-not \$root\) \{ Invoke-Json POST "\$base\/rootfolder"/);
  assert.doesNotMatch(script, /Invoke-Json PUT "\$base\/rootfolder/);
  assert.match(script, /Invoke-Json PUT "\$base\/downloadclient\/\$\(\$target\.id\)"/);
  assert.match(script, /Invoke-Json PUT "\$pBase\/applications\/\$\(\$application\.id\)"/);
  assert.match(script, /Invoke-Json PUT "\$pBase\/indexerProxy\/\$\(\$proxy\.id\)"/);
  assert.match(script, /Invoke-Json PUT "\$pBase\/indexer\/\$\(\$yts\.id\)\?forceSave=true"/);
  assert.match(script, /Invoke-Json POST http:\/\/localhost:8096\/Library\/VirtualFolders\/Paths\/Update/);
  assert.match(script, /@\{Name=\$folder\.Name;PathInfo=@\{Path=\$path\}\}/);
});

test('all Prowlarr indexer updates skip unreachable external provider tests', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  for (const resource of ['archive', 'yts', 'eztv', 'tokyo']) {
    assert.match(script, new RegExp(`Invoke-Json PUT "\\$pBase/indexer/\\$\\(\\$${resource}\\.id\\)\\?forceSave=true"`));
  }
});

test('provider reconciliation uses stable identities and only writes structural drift', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /function Find-Unique/);
  assert.match(script, /function Field-Value/);
  assert.match(script, /function Snapshot/);
  assert.match(script, /implementation -eq 'QBittorrent'[\s\S]+Field-Value \$_ 'host'\) -eq 'qbittorrent'/);
  assert.match(script, /implementation -eq \$target\.name/);
  assert.match(script, /implementation -eq 'FlareSolverr'/);
  assert.match(script, /implementation -eq 'MediaBrowser'/);
  assert.match(script, /CollectionType -eq \$collectionType/);
  assert.match(script, /Field-Value \$_ 'baseUrl'/);
  assert.match(script, /if \(\(Snapshot \$[a-zA-Z]+\) -ne \$before\) \{[\s\S]+Invoke-Json PUT/);
  assert.match(script, /if \(\$prowlarrChanged\) \{ Invoke-Json POST "\$pBase\/command"[^\n]+ApplicationIndexerSync/);
  assert.match(script, /if \(\$FirstRun -or \$jellyfinLibraryChanged\)[\s\S]+Library\/Refresh/);
  assert.match(script, /if \(\$bazarrChanged\)[\s\S]+action=sync/);
  assert.equal((script.match(/GET "\$pBase\/indexer\/schema"/g) ?? []).length, 1);
  assert.equal((script.match(/GET "\$pBase\/appprofile"/g) ?? []).length, 1);
});

test('ambiguous stable provider identities stop repair instead of creating duplicates', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  const helper = script.slice(script.indexOf('function Find-Unique'), script.indexOf('function Snapshot'));
  assert.match(helper, /\$candidates\.Count -gt 1/);
  assert.match(helper, /throw 'ambiguous_provider_identity:[^']+rename or remove duplicates[^']+'/);
  assert.match(helper, /\$candidates\.Count -eq 1/);
  const run = body => spawnSync('powershell.exe', [
    '-NoProfile', '-EncodedCommand', Buffer.from(`${helper}\n${body}`, 'utf16le').toString('base64'),
  ], { encoding: 'utf8' });
  const zero = run("if ($null -ne (Find-Unique @() { $true })) { throw 'expected_null' }");
  assert.equal(zero.status, 0, `${zero.stdout}\n${zero.stderr}`);
  const one = run("$item = Find-Unique @([pscustomobject]@{ id = 1 }) { $true }; if ($item.id -ne 1) { throw 'expected_item' }");
  assert.equal(one.status, 0, `${one.stdout}\n${one.stderr}`);
  const two = run("Find-Unique @([pscustomobject]@{ id = 1 }; [pscustomobject]@{ id = 2 }) { $true }");
  assert.notEqual(two.status, 0);
  assert.match(`${two.stdout}\n${two.stderr}`, /ambiguous_provider_identity:/);
});

test('Bazarr reconciliation adds missing Arr keys and restarts after profile failure', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /\$bazarrYamlChanged/);
  assert.match(script, /use_radarr/);
  assert.match(script, /use_sonarr/);
  assert.match(script, /apikey/);
  assert.match(script, /ip/);
  assert.match(script, /try \{[\s\S]+bazarr_profile\.py[\s\S]+\} catch \{[\s\S]+\}[\s\S]+finally \{[\s\S]+up -d bazarr/);
  const restart = script.indexOf('$bazarrRestartExitCode = $LASTEXITCODE');
  const restartCheck = script.indexOf('if ($bazarrRestartExitCode -ne 0)');
  const ready = script.indexOf('Bazarr profile ready');
  assert.ok(restart >= 0 && restartCheck > restart && ready > restartCheck);
  assert.match(script, /catch \{ \$profileError = \$_ \}[\s\S]+if \(\$profileError\) \{ throw \$profileError \}/);
  const stop = script.indexOf('docker compose --env-file $composeEnv stop bazarr');
  const stopCheck = script.indexOf("if ($LASTEXITCODE -ne 0) { throw 'Bazarr stop failed");
  const profileRun = script.indexOf('bazarr_profile.py');
  assert.ok(stop >= 0 && stopCheck > stop && profileRun > stopCheck);
  assert.match(script, /\$bazarrReady = \$false[\s\S]+for \(\$attempt = 0; \$attempt -lt 30; \$attempt\+\+\)[\s\S]+\$bazarrReady = \$true; break[\s\S]+if \(-not \$bazarrReady\) \{ throw 'bazarr_readiness_timeout:[^']+' \}/);
  assert.doesNotMatch(script, /\$movieApiBase\s*=\s*if/);
});

test('gateway recreation runs only when the Compose environment actually changes', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /\$composeEnvChanged = \$false/);
  assert.match(script, /\[string\]::Join\("`n", \$composeOriginal\) -ne \[string\]::Join\("`n", \$composeLines\)/);
  assert.match(script, /if \(\$composeEnvChanged\) \{[\s\S]+--force-recreate api[\s\S]+\}/);
  assert.doesNotMatch(script, /^docker compose[^\n]+--force-recreate api/m);
  const restart = script.indexOf('--force-recreate api');
  const failure = script.indexOf("if ($LASTEXITCODE -ne 0) { throw 'gateway_restart_failed:");
  const success = script.indexOf("Write-Output 'Configured qBittorrent");
  assert.ok(restart >= 0 && failure > restart && success > failure);
});

test('service readiness has no persisted state and treats Seerr as optional', () => {
  const script = fs.readFileSync(new URL('../../scripts/configure-services.sh', import.meta.url), 'utf8');
  assert.doesNotMatch(script, /STATE_DIR|state\.json/);
  assert.match(script, /required=\(qbittorrent prowlarr radarr sonarr bazarr jellyfin\)/);
  assert.match(script, /for index in "\$\{!required\[@\]\}"/);
  assert.match(script, /required_failed=1/);
  assert.doesNotMatch(script, /wait_for seerr/);
  assert.match(script, /curl -fsS --max-time 3 http:\/\/localhost:5055/);
  assert.match(script, /Seerr is optional/i);
});

test('Compose and bootstrap retire Autobrr and orphan dependencies without deleting data', () => {
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  const bootstrap = fs.readFileSync(new URL('../../scripts/bootstrap.sh', import.meta.url), 'utf8');
  assert.doesNotMatch(compose, /^\s{2}autobrr:/m);
  assert.doesNotMatch(compose, /^volumes:/m);
  assert.doesNotMatch(compose, /postgres_data|redis_data/);
  assert.doesNotMatch(bootstrap, /volume create media-stack-(?:postgres|redis)-data/);
  assert.doesNotMatch(bootstrap, /replace-with-a-long-random-password/);
  assert.doesNotMatch(bootstrap, /source "\$ENV_FILE"/);
  assert.match(bootstrap, /while IFS='=' read -r name value/);
  assert.match(bootstrap, /compose --env-file "\$COMPOSE_ENV_FILE" up -d --build --remove-orphans/);
  assert.match(bootstrap, /auto-configure\.ps1[^\r\n]+-MediaRoot[^\r\n]+-FirstRun/);
  assert.match(bootstrap, /COMPOSE_MEDIA_ROOT="\$\(wslpath -m "\$MEDIA_ROOT"\)"/);
  assert.doesNotMatch(bootstrap, /COMPOSE_MEDIA_ROOT="\$MEDIA_ROOT"/);
  assert.doesNotMatch(bootstrap, /require\(\)/);
});

test('example environment distinguishes required local settings from optional providers', () => {
  const environment = fs.readFileSync(new URL('../../.env.example', import.meta.url), 'utf8');
  const autoConfigure = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(environment, /^MEDIA_ROOT=\/mnt\/d\/Media$/m);
  assert.match(environment, /^MEDIA_ROOT_DOCKER=D:\/Media$/m);
  assert.match(environment, /^YTS_MOVIE_API_URL=https:\/\/movies-api\.accel\.li$/m);
  assert.doesNotMatch(environment, /^BAZARR_API_KEY=/m);
  assert.match(environment, /Required local settings/i);
  assert.match(environment, /Optional provider settings/i);
  assert.match(autoConfigure, /Add-Content \$EnvPath 'YTS_MOVIE_API_URL=https:\/\/movies-api\.accel\.li'/);
  assert.match(autoConfigure, /'YTS_MOVIE_API_URL','YIFY_DIRECT_ENABLED'/);
});
