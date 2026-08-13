import http from 'node:http';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { MediaClients } from './media-clients.mjs';
import { createServiceRegistry, publicService } from './services.mjs';
import { filterSubtitleResults, mergeSubtitleResults, normalizeSubtitle, shouldUseDirectFallback } from './subtitle-providers.mjs';
import { createSubtitleToken, verifySubtitleToken } from './subtitle-token.mjs';
import { safeArchiveEntry, safeSubtitleName, validateSubtitlePayload } from './subtitle-files.mjs';
import { YifyDirectProvider } from './yify-direct.mjs';
import { JsonTrendingStore, TrendingMovies, createSeerrFetcher, createYtsPopularFetcher } from './trending-movies.mjs';
import { TvProviderError, YtsOfficialTvProvider } from './yts-official-tv.mjs';

const registry = createServiceRegistry({
  qbittorrent: { url: process.env.QBITTORRENT_URL ?? 'http://qbittorrent:8080' },
  prowlarr: { url: process.env.PROWLARR_URL ?? 'http://prowlarr:9696' },
  radarr: { url: process.env.RADARR_URL ?? 'http://radarr:7878' },
  sonarr: { url: process.env.SONARR_URL ?? 'http://sonarr:8989' },
  bazarr: { url: process.env.BAZARR_URL ?? 'http://bazarr:6767' },
  jellyfin: { url: process.env.JELLYFIN_URL ?? 'http://jellyfin:8096' },
  seerr: { url: process.env.SEERR_URL ?? 'http://seerr:5055' },
});

const tvProvider = process.env.YTS_OFFICIAL_TV_ENABLED === 'false' ? null : new YtsOfficialTvProvider({
  baseUrl: process.env.YTS_OFFICIAL_TV_URL ?? 'https://en.yts-official.com/',
  secret: process.env.TV_DOWNLOAD_TOKEN_SECRET ?? 'local-development-change-me',
  cachePath: process.env.TRENDING_TV_CACHE ?? '/data/cache/trending-tv.json',
});

const media = new MediaClients({
  radarrUrl: registry.radarr.url,
  radarrConfig: process.env.RADARR_CONFIG ?? '/service-config/radarr.xml',
  sonarrUrl: registry.sonarr.url,
  sonarrConfig: process.env.SONARR_CONFIG ?? '/service-config/sonarr.xml',
  bazarrUrl: registry.bazarr.url,
  bazarrConfig: process.env.BAZARR_CONFIG ?? '/service-config/bazarr.yaml',
  qbitUrl: registry.qbittorrent.url,
  qbitUser: process.env.LOCAL_ADMIN_USER ?? 'admin',
  qbitPassword: process.env.LOCAL_ADMIN_PASSWORD ?? 'media1234',
  jellyfinUrl: registry.jellyfin.url,
  jellyfinApiKey: process.env.JELLYFIN_API_KEY,
  libraryRoot: process.env.MOVIES_ROOT ?? '/data/library/movies',
  tvProvider,
});

const subtitleTokenSecret = process.env.SUBTITLE_TOKEN_SECRET ?? 'local-development-change-me';
const yify = new YifyDirectProvider({
  enabled: process.env.YIFY_DIRECT_ENABLED === 'true',
  baseUrl: process.env.YIFY_DIRECT_BASE_URL ?? '',
});
const trending = new TrendingMovies({
  fetchPage: createSeerrFetcher({
    baseUrl: registry.seerr.url,
    configPath: process.env.SEERR_CONFIG ?? '/service-config/seerr/settings.json',
  }),
  store: new JsonTrendingStore(process.env.TRENDING_CACHE ?? '/data/cache/trending.json'),
  fetchFallback: createYtsPopularFetcher({ baseUrl: process.env.YTS_MOVIE_API_URL ?? 'https://movies-api.accel.li' }),
});
const execFileAsync = promisify(execFile);

async function unpackDirectSubtitle(downloaded) {
  if (downloaded.format !== 'zip') return downloaded;
  const archive = `/tmp/subtitle-${crypto.randomUUID()}.zip`;
  try {
    await fs.writeFile(archive, downloaded.buffer, { flag: 'wx' });
    const listing = await execFileAsync('unzip', ['-Z1', archive], { maxBuffer: 1024 * 1024 });
    const entries = listing.stdout.split(/\r?\n/).filter(Boolean).map(safeArchiveEntry);
    if (entries.length !== 1) throw new Error('unsafe archive');
    const extracted = await execFileAsync('unzip', ['-p', archive, entries[0]], { encoding: 'buffer', maxBuffer: 5 * 1024 * 1024 });
    return { buffer: Buffer.from(extracted.stdout), format: entries[0].split('.').pop().toLowerCase() };
  } finally { await fs.rm(archive, { force: true }); }
}

function validSubtitleQuery(language, provider) {
  return ['vi', 'en'].includes(language) && ['all', 'bazarr', 'yifysubtitles', 'gestdown', 'yify-direct'].includes(provider);
}

function bazarrResults(result, language, provider) {
  const raw = result?.data ?? result ?? [];
  return filterSubtitleResults(raw, language, provider === 'bazarr' ? 'all' : provider).map(value => ({
    ...normalizeSubtitle(value, 'bazarr'),
    downloadToken: createSubtitleToken({ source: 'bazarr', selection: value }, subtitleTokenSecret),
  }));
}

async function directResults(movie, language) {
  return (await yify.search(movie, language)).map(value => ({
    ...normalizeSubtitle(value, 'yify-direct'),
    downloadToken: createSubtitleToken({ source: 'yify-direct', subtitleId: value.subtitleId, language, mediaId: movie.mediaId }, subtitleTokenSecret),
  }));
}

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': '*' });
  res.end(JSON.stringify(body));
}

async function body(req, maxBytes = 1024 * 1024) {
  let value = '';
  for await (const chunk of req) {
    value += chunk;
    if (value.length > maxBytes) throw new Error('Request body too large');
  }
  return value ? JSON.parse(value) : {};
}

async function route(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (req.method === 'OPTIONS') return send(res, 204, {});
  if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { status: 'ready' });
  if (req.method === 'GET' && url.pathname === '/v1/services') return send(res, 200, Object.values(registry).map(publicService));
  if (req.method === 'GET' && url.pathname === '/v1/movies/trending') return send(res, 200, await trending.get());
  if (req.method === 'GET' && url.pathname === '/v1/movies/search') return send(res, 200, await media.searchMovies(url.searchParams.get('q') ?? ''));
  if (req.method === 'GET' && url.pathname === '/v1/series/search') return send(res, 200, await media.searchSeries(url.searchParams.get('q') ?? ''));
  if (req.method === 'GET' && url.pathname === '/v1/series/trending') return send(res, 200, tvProvider ? await tvProvider.trending() : { items: [], stale: false, source: 'unavailable' });

  let seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)$/);
  if (req.method === 'GET' && seriesMatch) return send(res, 200, media.normalizeSeries(await media.series(seriesMatch[1])));
  seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)\/episodes$/);
  if (req.method === 'GET' && seriesMatch) return send(res, 200, await media.seriesEpisodes(seriesMatch[1]));
  seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)\/releases$/);
  if (req.method === 'GET' && seriesMatch) {
    const episodeId = url.searchParams.get('episodeId');
    const seasonNumber = url.searchParams.get('seasonNumber');
    if (!episodeId && seasonNumber === null) return send(res, 400, { error: 'series_scope_required' });
    const releases = await media.seriesReleases(seriesMatch[1], episodeId ? { episodeId: Number(episodeId) } : { seasonNumber: Number(seasonNumber) });
    if (!episodeId && releases.length === 0) return send(res, 404, { error: 'season_pack_unavailable' });
    return send(res, 200, releases);
  }
  seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)\/download$/);
  if (req.method === 'POST' && seriesMatch) return send(res, 202, await media.downloadSeriesRelease(seriesMatch[1], await body(req)));

  let match = url.pathname.match(/^\/v1\/movies\/(\d+)$/);
  if (req.method === 'GET' && match) return send(res, 200, await media.movie(match[1]));
  match = url.pathname.match(/^\/v1\/movies\/(\d+)\/releases$/);
  if (req.method === 'GET' && match) return send(res, 200, await media.releases(match[1]));
  match = url.pathname.match(/^\/v1\/movies\/(\d+)\/download$/);
  if (req.method === 'POST' && match) return send(res, 202, await media.downloadRelease(match[1], await body(req)));

  if (req.method === 'GET' && url.pathname === '/v1/downloads') return send(res, 200, await media.downloads());
  match = url.pathname.match(/^\/v1\/downloads\/([a-fA-F0-9]+)\/(pause|resume|retry)$/);
  if (req.method === 'POST' && match) { await media.torrentAction(match[2], match[1]); return send(res, 202, { hash: match[1], action: match[2] }); }
  match = url.pathname.match(/^\/v1\/downloads\/([a-fA-F0-9]+)$/);
  if (req.method === 'DELETE' && match) { await media.torrentAction('delete', match[1]); return send(res, 202, { hash: match[1], action: 'delete' }); }

  if (req.method === 'GET' && url.pathname === '/v1/library') return send(res, 200, await media.library());
  if (req.method === 'POST' && url.pathname === '/v1/library/refresh') { await media.refreshJellyfin(); return send(res, 202, { state: 'scanning' }); }
  if (req.method === 'GET' && url.pathname === '/v1/library/subtitle-media') return send(res, 200, await media.subtitleMedia());
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles$/);
  if (req.method === 'GET' && match) return send(res, 200, await media.managedSubtitles(match[1]));
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/upload$/);
  if (req.method === 'POST' && match) return send(res, 201, await media.uploadLocalSubtitle(match[1], await body(req, 7 * 1024 * 1024)));
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/search$/);
  if (req.method === 'GET' && match) {
    const language = url.searchParams.get('language') ?? 'vi';
    const provider = url.searchParams.get('provider') ?? 'all';
    if (!validSubtitleQuery(language, provider)) return send(res, 400, { error: 'invalid_request' });
    const movie = await media.subtitleMovie(match[1]);
    let bazarr = [];
    if (provider !== 'yify-direct') bazarr = bazarrResults(await media.searchSubtitles(match[1], language), language, provider);
    const directEnabled = url.searchParams.get('directFallback') === 'true';
    let direct = [];
    if (provider === 'yify-direct' || shouldUseDirectFallback({ enabled: directEnabled && yify.enabled }, bazarr)) direct = await directResults(movie, language);
    return send(res, 200, { data: mergeSubtitleResults([bazarr, direct]), directEnabled: yify.enabled });
  }
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/yify\/search$/);
  if (req.method === 'GET' && match) {
    const language = url.searchParams.get('language') ?? 'vi';
    if (!['vi', 'en'].includes(language)) return send(res, 400, { error: 'invalid_request' });
    return send(res, 200, { data: await directResults(await media.subtitleMovie(match[1]), language), directEnabled: yify.enabled });
  }
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/download$/);
  if (req.method === 'POST' && match) {
    const value = await body(req);
    if (!value.downloadToken) return send(res, 400, { error: 'download_token_required' });
    const payload = verifySubtitleToken(value.downloadToken, subtitleTokenSecret);
    if (payload.source === 'bazarr') return send(res, 202, await media.downloadSubtitle(match[1], payload.selection));
    if (payload.source !== 'yify-direct' || String(payload.mediaId) !== match[1]) return send(res, 400, { error: 'invalid_token_scope' });
    const movie = await media.subtitleMovie(match[1]);
    const downloaded = await unpackDirectSubtitle(await yify.download(payload.subtitleId));
    validateSubtitlePayload(downloaded.buffer, downloaded.format);
    const target = safeSubtitleName(movie.path, payload.language, downloaded.format);
    const temporary = `${target}.tmp`;
    await fs.writeFile(temporary, downloaded.buffer, { flag: 'wx' });
    await fs.rename(temporary, target);
    await media.refreshSubtitles(match[1]);
    await media.refreshJellyfin();
    return send(res, 202, { mediaId: Number(match[1]), language: payload.language, provider: 'YIFY Direct' });
  }
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/([^/]+)$/);
  if (req.method === 'DELETE' && match) return send(res, 202, await media.deleteLocalSubtitle(match[1], match[2]));
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/refresh$/);
  if (req.method === 'POST' && match) return send(res, 202, await media.refreshSubtitles(match[1]));
  match = url.pathname.match(/^\/v1\/library\/(\d+)$/);
  if (req.method === 'DELETE' && match) {
    const value = await body(req);
    if (value.deleteFiles !== true || value.deleteTorrent !== true) return send(res, 400, { error: 'delete_confirmation_required' });
    return send(res, 200, await media.deleteManagedMovie(match[1]));
  }

  return send(res, 404, { error: 'not_found' });
}

http.createServer((req, res) => route(req, res).catch(error => {
  if (error instanceof TvProviderError || ['invalid_download_token', 'download_client_rejected'].includes(error.code ?? error.message)) {
    const code = error.code ?? error.message;
    const status = code === 'yts_tv_release_unavailable' ? 404 : code === 'invalid_download_token' ? 400 : 502;
    return send(res, status, { error: code });
  }
  send(res, 502, { error: 'upstream_failed', message: error.message });
})).listen(Number(process.env.PORT ?? 3000), '0.0.0.0');
