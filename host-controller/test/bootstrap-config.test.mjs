import test from 'node:test';
import assert from 'node:assert/strict';
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

test('bootstrap reports Public Domain Torrents as requiring a manual compatible feed when Prowlarr has no schema', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Public Domain Torrents/);
  assert.match(script, /needs_manual_feed/);
});

test('bootstrap updates existing PowerShell object properties without duplicate Add-Member failures', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Add-Member -Force -NotePropertyName \$name -NotePropertyValue \$value/);
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
  assert.equal((compose.match(/logging: \*logging/g) ?? []).length, 4);
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
