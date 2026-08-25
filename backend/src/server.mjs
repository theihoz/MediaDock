import http from 'node:http';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { createDownloadEventsHub } from './download-events.mjs';
import { MediaClients } from './media-clients.mjs';
import { createServiceRegistry, publicService } from './services.mjs';
import { mergeSubtitleResults, normalizeSubtitle, selectSubtitleResults, shouldUseDirectFallback } from './subtitle-providers.mjs';
import { createSubtitleToken, verifySubtitleToken } from './subtitle-token.mjs';
import { safeArchiveEntry, safeSubtitleName, validateSubtitlePayload } from './subtitle-files.mjs';
import { YifyDirectProvider } from './yify-direct.mjs';
import { JsonTrendingStore, TrendingMovies, createSeerrFetcher, createYtsPopularFetcher } from './trending-movies.mjs';
import { YtsOfficialTvProvider } from './yts-official-tv.mjs';
import { UnifiedSearch } from './unified-search.mjs';

const registry = createServiceRegistry({
  qbittorrent: { url: process.env.QBITTORRENT_URL ?? 'http://qbittorrent:8080' },
  prowlarr: { url: process.env.PROWLARR_URL ?? 'http://prowlarr:9696' },
  radarr: { url: process.env.RADARR_URL ?? 'http://radarr:7878' },
  sonarr: { url: process.env.SONARR_URL ?? 'http://sonarr:8989' },
  bazarr: { url: process.env.BAZARR_URL ?? 'http://bazarr:6767' },
  jellyfin: { url: process.env.JELLYFIN_URL ?? 'http://jellyfin:8096' },
  seerr: { url: process.env.SEERR_URL ?? 'http://seerr:5055' },
});

const tvReleaseProvider = new YtsOfficialTvProvider({
  baseUrl: process.env.YTS_OFFICIAL_TV_URL ?? 'https://en.yts-official.com/',
  secret: process.env.TV_DOWNLOAD_TOKEN_SECRET ?? 'local-development-change-me',
  cachePath: process.env.TRENDING_TV_CACHE ?? '/data/cache/trending-tv.json',
});
const tvProvider = process.env.YTS_OFFICIAL_TV_ENABLED === 'false' ? null : tvReleaseProvider;

const media = new MediaClients({
  radarrUrl: registry.radarr.url,
  radarrConfig: process.env.RADARR_CONFIG ?? '/service-config/radarr.xml',
  sonarrUrl: registry.sonarr.url,
  sonarrConfig: process.env.SONARR_CONFIG ?? '/service-config/sonarr.xml',
  prowlarrUrl: registry.prowlarr.url,
  prowlarrConfig: process.env.PROWLARR_CONFIG ?? '/service-config/prowlarr.xml',
  bazarrUrl: registry.bazarr.url,
  bazarrConfig: process.env.BAZARR_CONFIG ?? '/service-config/bazarr.yaml',
  qbitUrl: registry.qbittorrent.url,
  qbitUser: process.env.LOCAL_ADMIN_USER ?? 'admin',
  qbitPassword: process.env.LOCAL_ADMIN_PASSWORD ?? 'media1234',
  jellyfinUrl: registry.jellyfin.url,
  jellyfinApiKey: process.env.JELLYFIN_API_KEY,
  libraryRoot: process.env.MOVIES_ROOT ?? '/data/library/movies',
  tvProvider: tvReleaseProvider,
  tvDirectEnabled: Boolean(tvProvider),
});
const unifiedSearch = new UnifiedSearch({
  movieSearch: query => media.searchMovies(query),
  seriesSearch: query => media.searchSeries(query),
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
  return ['vi', 'en'].includes(language) && ['all', 'bazarr', 'yifysubtitles', 'gestdown', 'opensubtitlescom', 'yify-direct'].includes(provider);
}

function bazarrResults(result, language, provider, mediaType = 'movie') {
  const raw = result?.data ?? result ?? [];
  return selectSubtitleResults(raw, language, provider === 'bazarr' ? 'all' : provider).map(value => ({
    ...normalizeSubtitle(value, 'bazarr'),
    fallback: value.fallback === true,
    downloadToken: createSubtitleToken({ source: 'bazarr', mediaType, selection: value }, subtitleTokenSecret),
  }));
}

async function directResults(movie, language) {
  return (await yify.search(movie, language)).map(value => ({
    ...normalizeSubtitle(value, 'yify-direct'),
    downloadToken: createSubtitleToken({ source: 'yify-direct', subtitleId: value.subtitleId, language, mediaId: movie.mediaId }, subtitleTokenSecret),
  }));
}

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

async function body(req, maxBytes = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    let oversized = false;
    req.on('data', chunk => {
      if (oversized) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      bytes += buffer.length;
      if (bytes > maxBytes) {
        oversized = true;
        chunks.length = 0;
      } else {
        chunks.push(buffer);
      }
    });
    req.once('end', () => {
      if (oversized) {
        const error = new Error('request_too_large');
        error.code = 'request_too_large';
        reject(error);
        return;
      }
      try {
        const text = Buffer.concat(chunks).toString('utf8');
        const value = text ? JSON.parse(text) : {};
        if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_request');
        resolve(value);
      } catch (cause) {
        const error = new Error('invalid_request', { cause });
        error.code = 'invalid_request';
        reject(error);
      }
    });
    req.once('error', reject);
  });
}

function publicError(error) {
  const code = error?.code ?? error?.message;
  if (code === 'request_too_large') return { status: 413, error: 'request_too_large' };
  if (['invalid_request', 'invalid_download_token', 'invalid_token_scope', 'download_token_required', 'delete_confirmation_required'].includes(code)) {
    return { status: 400, error: 'invalid_request' };
  }
  if (['not_found', 'Movie not found', 'Series not found', 'season_pack_unavailable', 'tv_release_unavailable', 'yts_tv_release_unavailable'].includes(code)) {
    return { status: 404, error: 'not_found' };
  }
  if (['conflict', 'download_client_rejected', 'EEXIST'].includes(code)) return { status: 409, error: 'conflict' };
  if (code === 'upstream_timeout') return { status: 504, error: 'upstream_timeout' };
  return { status: 502, error: 'provider_unavailable' };
}

async function route(req, res, dependencies) {
  const { registry, media, unifiedSearch, trending, tvProvider, yify, subtitleTokenSecret, downloadEvents } = dependencies;
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (req.method === 'OPTIONS') return send(res, 204, {});
  if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { status: 'ready' });
  if (req.method === 'GET' && url.pathname === '/v1/services') return send(res, 200, Object.values(registry).map(publicService));
  if (req.method === 'GET' && url.pathname === '/v1/sources') return send(res, 200, await media.downloadSources());
  if (req.method === 'GET' && url.pathname === '/v1/discover/search') return send(res, 200, await unifiedSearch.search({
    query: url.searchParams.get('q') ?? '',
    type: url.searchParams.get('type') ?? 'all',
    year: url.searchParams.get('year'),
    library: url.searchParams.get('library') ?? 'all',
    limit: url.searchParams.get('limit') ?? 50,
  }));
  if (req.method === 'GET' && url.pathname === '/v1/movies/trending') return send(res, 200, await trending.get());
  if (req.method === 'GET' && url.pathname === '/v1/movies/search') return send(res, 200, await media.searchMovies(url.searchParams.get('q') ?? ''));
  if (req.method === 'GET' && url.pathname === '/v1/series/search') return send(res, 200, await media.searchSeries(url.searchParams.get('q') ?? ''));
  if (req.method === 'GET' && url.pathname === '/v1/series/trending') return send(res, 200, tvProvider ? await tvProvider.trending() : { items: [], stale: false, source: 'unavailable' });

  let seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)$/);
  if (req.method === 'GET' && seriesMatch) return send(res, 200, media.normalizeSeries(await media.series(seriesMatch[1])));
  seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)\/episodes$/);
  if (req.method === 'GET' && seriesMatch) return send(res, 200, await media.seriesEpisodes(seriesMatch[1]));
  if (req.method === 'POST' && seriesMatch) return send(res, 200, { items: await media.seriesEpisodes(seriesMatch[1]), prepared: true });
  seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)\/releases$/);
  if (req.method === 'GET' && seriesMatch) {
    const episodeId = url.searchParams.get('episodeId');
    const seasonNumber = url.searchParams.get('seasonNumber');
    if (!episodeId && seasonNumber === null) return send(res, 400, { error: 'invalid_request' });
    const freePublicDomain = url.searchParams.get('freePublicDomain') === 'true';
    const releases = await media.seriesReleases(
      seriesMatch[1],
      episodeId ? { episodeId: Number(episodeId), freePublicDomain } : { seasonNumber: Number(seasonNumber), freePublicDomain },
      { force: url.searchParams.get('refresh') === 'true' },
    );
    if (!episodeId && releases.length === 0) return send(res, 404, { error: 'not_found' });
    return send(res, 200, releases);
  }
  if (req.method === 'POST' && seriesMatch) {
    const value = await body(req);
    const object = value !== null && typeof value === 'object' && !Array.isArray(value);
    const hasSeason = object && Object.hasOwn(value, 'seasonNumber');
    const hasEpisode = object && Object.hasOwn(value, 'episodeId');
    const hasFree = object && Object.hasOwn(value, 'freePublicDomain');
    const validSeason = hasSeason && Number.isSafeInteger(value.seasonNumber) && value.seasonNumber >= 0;
    const validEpisode = hasEpisode && Number.isSafeInteger(value.episodeId) && value.episodeId > 0;
    if (hasSeason === hasEpisode || (hasSeason && !validSeason) || (hasEpisode && !validEpisode) || (hasFree && typeof value.freePublicDomain !== 'boolean')) {
      return send(res, 400, { error: 'invalid_request' });
    }
    const selection = hasEpisode ? { episodeId: value.episodeId } : { seasonNumber: value.seasonNumber };
    if (hasFree) selection.freePublicDomain = value.freePublicDomain;
    return send(res, 200, await media.prepareSeriesReleases(seriesMatch[1], selection, { force: url.searchParams.get('refresh') === 'true' }));
  }
  seriesMatch = url.pathname.match(/^\/v1\/series\/(\d+)\/download$/);
  if (req.method === 'POST' && seriesMatch) return send(res, 202, await media.downloadSeriesRelease(seriesMatch[1], await body(req)));

  let match = url.pathname.match(/^\/v1\/movies\/(\d+)$/);
  if (req.method === 'GET' && match) return send(res, 200, await media.movie(match[1]));
  match = url.pathname.match(/^\/v1\/movies\/(\d+)\/releases$/);
  if (req.method === 'GET' && match) return send(res, 200, await media.releases(match[1], {
    freePublicDomain: url.searchParams.get('freePublicDomain') === 'true',
    force: url.searchParams.get('refresh') === 'true',
  }));
  if (req.method === 'POST' && match) return send(res, 200, await media.prepareMovieReleases(match[1], {
    freePublicDomain: url.searchParams.get('freePublicDomain') === 'true',
    force: url.searchParams.get('refresh') === 'true',
  }));
  match = url.pathname.match(/^\/v1\/movies\/(\d+)\/download$/);
  if (req.method === 'POST' && match) return send(res, 202, await media.downloadRelease(match[1], await body(req)));

  if (req.method === 'GET' && url.pathname === '/v1/downloads/events') return downloadEvents.subscribe(res);
  if (req.method === 'GET' && url.pathname === '/v1/downloads') return send(res, 200, await media.downloads());
  match = url.pathname.match(/^\/v1\/downloads\/([a-fA-F0-9]+)\/(pause|resume|retry)$/);
  if (req.method === 'POST' && match) { await media.torrentAction(match[2], match[1]); return send(res, 202, { hash: match[1], action: match[2] }); }
  match = url.pathname.match(/^\/v1\/downloads\/([a-fA-F0-9]+)$/);
  if (req.method === 'DELETE' && match) { await media.torrentAction('delete', match[1]); return send(res, 202, { hash: match[1], action: 'delete' }); }

  if (req.method === 'GET' && url.pathname === '/v1/library') return send(res, 200, await media.library());
  if (req.method === 'POST' && url.pathname === '/v1/library/refresh') { await media.refreshJellyfin(); return send(res, 202, { state: 'scanning' }); }
  if (req.method === 'GET' && url.pathname === '/v1/library/subtitle-media') return send(res, 200, await media.subtitleMedia());
  match = url.pathname.match(/^\/v1\/library\/subtitle-media\/(\d+)\/seasons\/(\d+)$/);
  if (req.method === 'GET' && match) return send(res, 200, await media.subtitleSeason(match[1], match[2]));
  match = url.pathname.match(/^\/v1\/library\/subtitle-media\/(\d+)\/seasons\/(\d+)\/search$/);
  if (req.method === 'POST' && match) return send(res, 202, await media.searchSeasonSubtitles(match[1], match[2]));
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles$/);
  if (req.method === 'GET' && match) return send(res, 200, await media.managedSubtitles(match[1]));
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/upload$/);
  if (req.method === 'POST' && match) return send(res, 201, await media.uploadLocalSubtitle(match[1], await body(req, 7 * 1024 * 1024)));
  match = url.pathname.match(/^\/v1\/library\/(\d+)\/subtitles\/search$/);
  if (req.method === 'GET' && match) {
    const language = url.searchParams.get('language') ?? 'vi';
    const provider = url.searchParams.get('provider') ?? 'all';
    const mediaType = url.searchParams.get('mediaType') ?? 'movie';
    if (!validSubtitleQuery(language, provider)) return send(res, 400, { error: 'invalid_request' });
    if (!['movie', 'episode'].includes(mediaType) || (mediaType === 'episode' && provider === 'yify-direct')) return send(res, 400, { error: 'invalid_request' });
    if (mediaType === 'episode') {
      const result = provider === 'all'
        ? await media.searchAllEpisodeSubtitles(match[1])
        : await media.searchEpisodeSubtitles(match[1], language);
      const bazarr = bazarrResults(result, language, provider, 'episode');
      return send(res, 200, { data: bazarr, directEnabled: false });
    }
    const movie = await media.subtitleMovie(match[1]);
    let bazarr = [];
    if (provider !== 'yify-direct') {
      const result = provider === 'all'
        ? await media.searchAllSubtitles(match[1])
        : await media.searchSubtitles(match[1], language);
      bazarr = bazarrResults(result, language, provider);
    }
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
    if (!value.downloadToken) return send(res, 400, { error: 'invalid_request' });
    const payload = verifySubtitleToken(value.downloadToken, subtitleTokenSecret);
    if (payload.source === 'bazarr') return send(res, 202, payload.mediaType === 'episode'
      ? await media.downloadEpisodeSubtitle(match[1], payload.selection)
      : await media.downloadSubtitle(match[1], payload.selection));
    if (payload.source !== 'yify-direct' || String(payload.mediaId) !== match[1]) return send(res, 400, { error: 'invalid_request' });
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
  if (req.method === 'POST' && match) return send(res, 202, url.searchParams.get('mediaType') === 'episode'
    ? await media.refreshEpisodeSubtitles(match[1])
    : await media.refreshSubtitles(match[1]));
  match = url.pathname.match(/^\/v1\/library\/(\d+)$/);
  if (req.method === 'DELETE' && match) {
    const value = await body(req);
    if (value.deleteFiles !== true || value.deleteTorrent !== true) return send(res, 400, { error: 'invalid_request' });
    return send(res, 200, await media.deleteManagedMovie(match[1]));
  }

  return send(res, 404, { error: 'not_found' });
}

const defaultDependencies = {
  registry, media, unifiedSearch, trending, tvProvider, yify, subtitleTokenSecret,
  downloadEvents: createDownloadEventsHub(signal => media.downloads({ signal })),
};

export function createServer(overrides = {}) {
  const dependencies = { ...defaultDependencies, ...overrides };
  return http.createServer((req, res) => route(req, res, dependencies).catch(error => {
    const failure = publicError(error);
    send(res, failure.status, { error: failure.error });
  }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createServer().listen(Number(process.env.PORT ?? 3000), '0.0.0.0');
}
