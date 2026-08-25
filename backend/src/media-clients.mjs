import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { decodeSubtitleUpload, normalizeLibraryMovie, normalizeLibrarySeries, subtitleFileName, subtitleIdFromName, subtitleNameFromId } from './media-library.mjs';
import { matchesTvTitleScope } from './yts-official-tv.mjs';

export function extractApiKey(text) {
  const match = text.match(/<ApiKey>([^<]+)<\/ApiKey>/i) ?? text.match(/^\s*apikey:\s*['"]?([^'"\s]+)['"]?\s*$/im);
  if (!match) throw new Error('API key not found');
  return match[1];
}

export function apiKeyFrom(path) {
  return extractApiKey(fs.readFileSync(path, 'utf8'));
}

function sourceGroupFromName(value) {
  return /^(Internet Archive|Public Domain Torrents)(?:\s*\([^)]*\))?$/i.test(value ?? '') ? 'free_public_domain' : 'default';
}

export function normalizeRelease(value) {
  const title = value.title ?? '';
  const codec = /(?:x|h)[ ._-]?265|hevc/i.test(title) ? 'H.265' : /av1/i.test(title) ? 'AV1' : /(?:x|h)[ ._-]?264|avc/i.test(title) ? 'H.264' : 'Unknown';
  const rejections = value.rejections ?? [];
  const onlyNeedsMonitoring = rejections.length > 0 && rejections.every(reason => /^Episode wasn't requested:/i.test(reason));
  const duplicateImported = rejections.some(reason => /same torrent hash as a grabbed and imported release/i.test(reason));
  return {
    guid: value.guid,
    indexerId: value.indexerId,
    source: value.indexer ?? value.indexerName ?? 'Prowlarr',
    sourceGroup: sourceGroupFromName(value.indexer ?? value.indexerName),
    title,
    size: value.size ?? 0,
    seeders: value.seeders ?? 0,
    peers: value.peers ?? 0,
    quality: value.quality?.quality?.name ?? 'Unknown',
    resolution: value.quality?.quality?.resolution ?? 0,
    codec,
    rejected: onlyNeedsMonitoring ? false : Boolean(value.rejected ?? rejections.length),
    downloadable: Boolean(value.guid) && !duplicateImported,
    rejections,
  };
}

export function normalizeTorrent(value) {
  return {
    hash: value.hash,
    name: value.name,
    progress: Math.round((value.progress ?? 0) * 10000) / 100,
    downloadSpeed: value.dlspeed ?? 0,
    uploadSpeed: value.upspeed ?? 0,
    eta: value.eta ?? 0,
    size: value.size ?? 0,
    state: value.state ?? 'unknown',
    category: value.category ?? '',
  };
}

export function loginSucceeded(status, text) {
  return status === 204 || (status >= 200 && status < 300 && text.trim() === 'Ok.');
}

export function filterSubtitleResults(items, language) {
  if (!language) return items;
  return items.filter(item => (item.language ?? item.code2 ?? item.lang) === language);
}

export function buildSubtitleDownloadQuery(radarrId, value) {
  if (!value.provider) throw new Error('provider is required');
  if (!value.subtitle) throw new Error('subtitle is required');
  return new URLSearchParams({
    radarrid: String(radarrId),
    hi: String(Boolean(value.hi)),
    forced: String(Boolean(value.forced)),
    original_format: String(Boolean(value.originalFormat ?? value.original_format)),
    provider: value.provider,
    subtitle: value.subtitle,
  }).toString();
}

export function buildSubtitleDeleteQuery(radarrId, value) {
  if (!value.language) throw new Error('language is required');
  if (!value.path) throw new Error('path is required');
  return new URLSearchParams({
    radarrid: String(radarrId),
    language: value.language,
    forced: String(Boolean(value.forced)),
    hi: String(Boolean(value.hi)),
    path: value.path,
  }).toString();
}

export function qbitActionEndpoint(action) {
  if (action === 'pause') return 'stop';
  if (action === 'resume' || action === 'retry') return 'start';
  return action;
}

export function normalizeSubtitleMedia(value) {
  return {
    mediaId: value.radarrId,
    title: value.title,
    year: Number(value.year || 0),
    path: value.path,
    imdbId: value.imdbId,
    poster: value.poster,
    type: 'movie',
  };
}

export function normalizeSubtitleEpisode(value) {
  const season = String(Number(value.season ?? value.seasonNumber ?? 0)).padStart(2, '0');
  const episode = String(Number(value.episode ?? value.episodeNumber ?? 0)).padStart(2, '0');
  return {
    mediaId: value.sonarrEpisodeId ?? value.episodeId,
    title: `${value.seriesTitle ?? value.title ?? 'TV Show'} S${season}E${episode}${value.episodeTitle ? ` • ${value.episodeTitle}` : ''}`,
    year: Number(value.year || 0),
    path: value.path,
    imdbId: value.imdbId ?? null,
    poster: value.poster ?? null,
    type: 'episode',
  };
}

function subtitleCode(value) {
  return String(value?.code2 ?? value?.language?.code2 ?? value?.language ?? value ?? '').toLowerCase();
}

function hasVietnameseSubtitle(value) {
  return (value?.subtitles ?? []).some(item => subtitleCode(item) === 'vi');
}

function summarizeSubtitleSeries(series, episodes, coverageDegraded = false) {
  const seasonMap = new Map();
  for (const episode of episodes) {
    const seasonNumber = Number(episode.season ?? episode.seasonNumber ?? 0);
    if (seasonNumber <= 0) continue;
    const season = seasonMap.get(seasonNumber) ?? { seasonNumber, episodeCount: 0, viAvailable: 0, viMissing: 0 };
    season.episodeCount += 1;
    if (hasVietnameseSubtitle(episode)) season.viAvailable += 1;
    else season.viMissing += 1;
    seasonMap.set(seasonNumber, season);
  }
  const seasons = [...seasonMap.values()].sort((left, right) => left.seasonNumber - right.seasonNumber);
  return {
    mediaId: series.id,
    title: series.title,
    year: Number(series.year || 0),
    poster: series.images?.find(image => image.coverType === 'poster')?.remoteUrl ?? null,
    type: 'series',
    episodeCount: seasons.reduce((sum, season) => sum + season.episodeCount, 0),
    viAvailable: seasons.reduce((sum, season) => sum + season.viAvailable, 0),
    viMissing: seasons.reduce((sum, season) => sum + season.viMissing, 0),
    coverageDegraded,
    seasons,
  };
}

function buildEpisodeSubtitleDownloadQuery(episodeId, value) {
  if (!value.provider || !value.subtitle) throw new Error('invalid subtitle selection');
  return new URLSearchParams({
    episodeid: String(episodeId), hi: String(Boolean(value.hi)), forced: String(Boolean(value.forced)),
    original_format: String(Boolean(value.originalFormat ?? value.original_format)), provider: value.provider, subtitle: value.subtitle,
  }).toString();
}

function infoHashFromReleaseGuid(guid) {
  const match = String(guid ?? '').match(/(?:download\/|btih:)([a-fA-F0-9]{40})(?:\b|$)/i);
  return match?.[1]?.toLowerCase() ?? null;
}

export async function jsonRequest(url, { timeoutMs = 8000, signal, ...options } = {}) {
  const controller = new AbortController();
  const abort = () => controller.abort(signal?.reason);
  if (signal?.aborted) abort();
  else signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => {
    const error = new Error('upstream_timeout');
    error.code = 'upstream_timeout';
    controller.abort(error);
  }, timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const text = await response.text();
    if (!response.ok) throw new Error(`${response.status} ${text.slice(0, 240)}`);
    return text ? JSON.parse(text) : null;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

async function timedFetch(url, { timeoutMs = 8000, signal, ...options } = {}) {
  const controller = new AbortController();
  const abort = () => controller.abort(signal?.reason);
  if (signal?.aborted) abort();
  else signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => {
    const error = new Error('upstream_timeout');
    error.code = 'upstream_timeout';
    controller.abort(error);
  }, timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', abort);
  }
}

async function partialSourceResults(sources, timeoutMs) {
  const settled = await Promise.all(sources.map(async ({ id, search }) => {
    const controller = new AbortController();
    let timer;
    let timedOut = false;
    try {
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => {
          timedOut = true;
          const error = new Error('upstream_timeout');
          error.code = 'upstream_timeout';
          controller.abort(error);
          reject(error);
        }, timeoutMs);
      });
      const value = await Promise.race([Promise.resolve().then(() => search(controller.signal)), timeout]);
      const items = Array.isArray(value) ? value : [];
      return { id, state: 'ready', items };
    } catch (error) {
      return { id, state: timedOut || error?.code === 'upstream_timeout' ? 'timeout' : 'failed', items: [] };
    } finally {
      clearTimeout(timer);
    }
  }));
  if (!settled.some(source => source.state === 'ready')) {
    const code = settled.every(source => source.state === 'timeout') ? 'upstream_timeout' : 'provider_unavailable';
    const error = new Error(code);
    error.code = code;
    throw error;
  }
  return {
    items: settled.flatMap(source => source.items),
    partial: settled.some(source => source.state !== 'ready'),
    sources: Object.fromEntries(settled.map(source => [source.id, { state: source.state, itemCount: source.items.length }])),
  };
}

async function mapLimit(items, limit, mapper) {
  const results = new Array(items.length);
  let cursor = 0;
  const worker = async () => {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await mapper(items[index], index);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

function importedDownloadIds(history) {
  const ids = new Set();
  for (const item of history?.records ?? history ?? []) {
    if (item.eventType !== 'downloadFolderImported') continue;
    const id = String(item.downloadId ?? item.data?.downloadId ?? '').toLowerCase();
    if (id) ids.add(id);
  }
  return ids;
}

function releaseIdentity(release) {
  const group = release.sourceGroup ?? 'default';
  const hash = infoHashFromReleaseGuid(release.guid);
  if (hash) return `hash:${hash}:${group}`;
  return `fallback:${String(release.title ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '')}:${release.size ?? 0}:${group}`;
}

export class ReleaseSearchCache {
  constructor({ ttlMs = 10 * 60 * 1000, partialTtlMs = 30 * 1000, timeoutMs = 15000, maxEntries = 200, now = Date.now } = {}) {
    this.ttlMs = ttlMs;
    this.partialTtlMs = partialTtlMs;
    this.timeoutMs = timeoutMs;
    this.maxEntries = maxEntries;
    this.now = now;
    this.values = new Map();
    this.inFlight = new Map();
  }

  async get(key, search, { force = false } = {}) {
    const now = this.now();
    for (const [cachedKey, value] of this.values) {
      if (value.expiresAt <= now) this.values.delete(cachedKey);
    }
    const cached = this.values.get(key);
    if (!force && cached) return cached.value;
    if (this.inFlight.has(key)) return this.inFlight.get(key);

    const pending = this.withTimeout(search()).then(value => {
      this.values.delete(key);
      this.values.set(key, { value, expiresAt: this.now() + (value?.partial === true ? this.partialTtlMs : this.ttlMs) });
      while (this.values.size > this.maxEntries) this.values.delete(this.values.keys().next().value);
      return value;
    }).finally(() => this.inFlight.delete(key));
    this.inFlight.set(key, pending);
    return pending;
  }

  async withTimeout(promise) {
    let timer;
    try {
      return await Promise.race([
        promise,
        new Promise((_, reject) => {
          timer = setTimeout(() => {
            const error = new Error('upstream_timeout');
            error.code = 'upstream_timeout';
            reject(error);
          }, this.timeoutMs);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }
}

export class MediaClients {
  constructor(config) {
    this.config = config;
    this.tvProvider = config.tvProvider;
    this.tvDirectEnabled = config.tvDirectEnabled ?? Boolean(config.tvProvider);
    this.qbitCookie = null;
    this.sourceTimeoutMs = config.sourceTimeoutMs ?? 8000;
    this.seasonSubtitleSearches = new Map();
    this.importedIdsCache = new Map();
    this.importedIdsRefreshes = new Map();
    this.importedIdsCacheTtlMs = config.importedIdsCacheTtlMs ?? 5000;
    this.tvSourceTimeoutMs = config.tvSourceTimeoutMs ?? 30000;
    this.episodeRetryDelayMs = config.episodeRetryDelayMs ?? 500;
    this.releaseCache = config.releaseCache ?? new ReleaseSearchCache({
      timeoutMs: Math.max(15000, this.tvSourceTimeoutMs + 1000),
    });
  }

  arrKey(name) { return apiKeyFrom(this.config[`${name}Config`]); }
  arrUrl(name, path) { return `${this.config[`${name}Url`]}/api/v3${path}`; }

  async arr(name, path, options = {}) {
    return jsonRequest(this.arrUrl(name, path), {
      ...options,
      headers: { 'x-api-key': this.arrKey(name), 'content-type': 'application/json', ...(options.headers ?? {}) },
    });
  }

  async prowlarr(path, options = {}) {
    return jsonRequest(`${this.config.prowlarrUrl}/api/v1${path}`, {
      ...options,
      headers: { 'x-api-key': apiKeyFrom(this.config.prowlarrConfig), 'content-type': 'application/json', ...(options.headers ?? {}) },
    });
  }

  async downloadSources() {
    let indexers;
    let statuses = [];
    try {
      const response = await this.prowlarr('/indexer');
      indexers = Array.isArray(response) ? response : Array.isArray(response?.value) ? response.value : [];
      try {
        const statusResponse = await this.prowlarr('/indexerstatus');
        statuses = Array.isArray(statusResponse) ? statusResponse : Array.isArray(statusResponse?.value) ? statusResponse.value : [];
      } catch {}
    } catch {
      indexers = null;
    }
    const detailsFor = (name, directAvailable = false) => {
      if (!indexers) return { state: 'degraded' };
      const indexer = indexers.find(item => item.name === name);
      if (!indexer?.enable && !directAvailable) return { state: 'disabled' };
      const status = statuses.find(item => Number(item.indexerId) === Number(indexer?.id));
      const failure = String(status?.mostRecentFailure ?? status?.errorMessage ?? '');
      if (/cloudflare|turnstile|just a moment/i.test(failure)) {
        return { state: 'cloudflare_blocked', reason: 'Cloudflare challenge requires attention' };
      }
      if (failure) return { state: 'degraded', reason: 'Indexer is temporarily unavailable' };
      return { state: 'ready' };
    };
    return [
      { id: 'yts-official', name: 'YTS Official', ...detailsFor('YTS', this.tvDirectEnabled), scopes: ['movie', 'series'] },
      { id: 'eztv', name: 'EZTV', ...detailsFor('EZTV'), scopes: ['series'] },
      { id: 'internet-archive', name: 'Internet Archive', ...detailsFor('Internet Archive'), scopes: ['movie', 'series'] },
      { id: 'tokyo-toshokan', name: 'Tokyo Toshokan', ...detailsFor('Tokyo Toshokan'), scopes: ['series'] },
      { id: 'nyaa-si', name: 'Nyaa.si', ...detailsFor('Nyaa.si'), scopes: ['movie', 'series'], endpoint: 'https://nyaa.si/' },
      { id: 'nyaa-land', name: 'Nyaa.land', ...detailsFor('Nyaa.land'), scopes: ['movie', 'series'], endpoint: 'https://nyaa.land/' },
      { id: 'public-domain-torrents', name: 'Public Domain Torrents', state: 'needs_manual_feed', scopes: ['movie'], reason: 'No compatible Prowlarr feed configured' },
    ];
  }

  async searchMovies(term) {
    const items = await this.arr('radarr', `/movie/lookup?term=${encodeURIComponent(term)}`);
    return items.map(item => ({ tmdbId: item.tmdbId, title: item.title, originalTitle: item.originalTitle, aliases: (item.alternativeTitles ?? []).map(value => value.title).filter(Boolean), studios: item.studio ? [item.studio] : [], people: [], year: item.year, overview: item.overview, poster: item.remotePoster, runtime: item.runtime, genres: item.genres ?? [], inLibrary: Boolean(item.id) }));
  }

  normalizeSeries(item) {
    return { mediaType: 'series', tvdbId: item.tvdbId, title: item.title, originalTitle: item.originalTitle, aliases: (item.alternateTitles ?? []).map(value => value.title).filter(Boolean), studios: item.studio ? [item.studio] : [], networks: item.network ? [item.network] : [], people: [], year: item.year, overview: item.overview, poster: item.remotePoster, inLibrary: Boolean(item.id), seasons: item.seasons ?? [] };
  }

  async searchSeries(term) {
    return (await this.arr('sonarr', `/series/lookup?term=${encodeURIComponent(term)}`)).map(item => this.normalizeSeries(item));
  }

  async series(tvdbId) {
    const items = await this.arr('sonarr', `/series/lookup?term=tvdb:${encodeURIComponent(tvdbId)}`);
    if (!items[0]) throw new Error('Series not found');
    return items[0];
  }

  async ensureSeries(tvdbId) {
    const existing = await this.arr('sonarr', `/series?tvdbId=${encodeURIComponent(tvdbId)}`);
    if (existing[0]) return existing[0];
    const series = await this.series(tvdbId);
    const profiles = await this.arr('sonarr', '/qualityprofile');
    return this.arr('sonarr', '/series', { method: 'POST', body: JSON.stringify({
      ...series, qualityProfileId: profiles[0]?.id, rootFolderPath: '/data/library/series', monitored: false, seasonFolder: true, addOptions: { monitor: 'none', searchForMissingEpisodes: false, searchForCutoffUnmetEpisodes: false },
    }) });
  }

  async seriesEpisodes(tvdbId) {
    const series = await this.ensureSeries(tvdbId);
    let rows = [];
    for (let attempt = 0; attempt < 10; attempt += 1) {
      rows = await this.arr('sonarr', `/episode?seriesId=${series.id}`);
      if (rows.length || attempt === 9) break;
      await new Promise(resolve => setTimeout(resolve, this.episodeRetryDelayMs));
    }
    return rows.map(item => ({ episodeId: item.id, seasonNumber: item.seasonNumber, episodeNumber: item.episodeNumber, title: item.title, airDate: item.airDate, hasFile: Boolean(item.hasFile) }));
  }

  async prepareSeriesReleases(tvdbId, selection, { force = false } = {}) {
    const cacheKey = selection.episodeId ? `series:${tvdbId}:episode:${selection.episodeId}` : `series:${tvdbId}:season:${selection.seasonNumber}`;
    const result = await this.releaseCache.get(cacheKey, async () => {
      if (!this.tvProvider) {
        const error = new Error('provider_unavailable');
        error.code = 'provider_unavailable';
        throw error;
      }
      const series = await this.ensureSeries(tvdbId);
      let scope;
      if (selection.episodeId) {
        const episode = await this.arr('sonarr', `/episode/${encodeURIComponent(selection.episodeId)}`);
        scope = { tvdbId: Number(tvdbId), title: series.title, year: series.year, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber };
      } else {
        scope = { tvdbId: Number(tvdbId), title: series.title, year: series.year, seasonNumber: Number(selection.seasonNumber) };
      }
      const path = selection.episodeId
        ? `/release?episodeId=${encodeURIComponent(selection.episodeId)}`
        : `/release?seriesId=${series.id}&seasonNumber=${encodeURIComponent(selection.seasonNumber)}`;
      const normalizeArr = async signal => {
        let rows = await this.arr('sonarr', path, { signal });
        rows = rows.filter(row => row.guid && Number.isInteger(Number(row.indexerId)) && matchesTvTitleScope(row.title ?? '', scope));
        rows.sort((left, right) => Number(!/EZTV/i.test(left.indexer ?? left.indexerName ?? '')) - Number(!/EZTV/i.test(right.indexer ?? right.indexerName ?? '')));
        return rows.map(row => ({ ...this.tvProvider.normalizeSonarr(row, scope), sourceMode: 'prowlarr', sourceGroup: sourceGroupFromName(row.indexer ?? row.indexerName) }));
      };
      const sources = [{ id: 'sonarr', search: normalizeArr }];
      if (this.tvDirectEnabled) {
        sources.unshift({ id: 'yts', search: async signal => (await this.tvProvider.search(scope, { signal })).map(release => ({ ...release, sourceMode: 'yts', sourceGroup: sourceGroupFromName(release.source) })) });
      }
      const releases = await partialSourceResults(sources, this.tvSourceTimeoutMs);
      return { ...releases, items: [...new Map(releases.items.map(release => [releaseIdentity(release), release])).values()] };
    }, { force });
    const items = selection.freePublicDomain
      ? result.items.filter(release => release.sourceGroup === 'free_public_domain')
      : result.items;
    const sources = Object.fromEntries(Object.entries(result.sources).map(([id, source]) => [id, {
      ...source,
      itemCount: items.filter(release => id === 'yts' ? release.sourceMode === 'yts' : release.sourceMode !== 'yts').length,
    }]));
    return { ...result, items, sources, prepared: true };
  }

  async seriesReleases(tvdbId, selection, options = {}) {
    return (await this.prepareSeriesReleases(tvdbId, selection, options)).items;
  }

  async downloadSeriesRelease(tvdbId, selection) {
    if (!selection.downloadToken || !this.tvProvider) throw new Error('invalid_download_token');
    const series = await this.ensureSeries(tvdbId);
    let episode;
    const scope = { tvdbId: Number(tvdbId), seasonNumber: Number(selection.seasonNumber) };
    if (selection.episodeId) {
      episode = await this.arr('sonarr', `/episode/${encodeURIComponent(selection.episodeId)}`);
      scope.seasonNumber = Number(episode.seasonNumber);
      scope.episodeNumber = Number(episode.episodeNumber);
    }
    const release = this.tvProvider.resolveToken(selection.downloadToken, scope);
    // Tokens issued before multi-provider support did not include sourceMode.
    // A verified magnet can only be a direct YTS release, so keep them valid.
    release.sourceMode ??= release.magnetUrl ? 'yts' : 'prowlarr';
    if (release.sourceMode === 'yts') {
      if (!this.tvDirectEnabled) throw new Error('invalid_download_token');
      const torrents = await this.qbit('/torrents/info');
      if ((torrents ?? []).some(torrent => String(torrent.hash).toLowerCase() === release.infoHash)) {
        return { accepted: true, duplicate: true, hash: release.infoHash };
      }
    }
    if (episode) {
      await this.arr('sonarr', `/episode/${encodeURIComponent(selection.episodeId)}`, {
        method: 'PUT', body: JSON.stringify({ ...episode, monitored: true }),
      });
    } else if (selection.seasonNumber !== undefined) {
      const seasonNumber = Number(selection.seasonNumber);
      await this.arr('sonarr', `/series/${series.id}`, {
        method: 'PUT', body: JSON.stringify({
          ...series,
          seasons: (series.seasons ?? []).map(season => ({
            ...season, monitored: Number(season.seasonNumber) === seasonNumber ? true : season.monitored,
          })),
        }),
      });
    }
    try {
      if (release.sourceMode === 'prowlarr') {
        await this.arr('sonarr', '/release', { method: 'POST', body: JSON.stringify({ guid: release.guid, indexerId: release.indexerId }) });
      } else {
        await this.qbit('/torrents/add', { method: 'POST', body: new URLSearchParams({ urls: release.magnetUrl, category: 'series' }) });
      }
    } catch {
      const error = new Error('download_client_rejected'); error.code = 'download_client_rejected'; throw error;
    }
    return { accepted: true, duplicate: false, hash: release.infoHash };
  }

  async movie(tmdbId) {
    const items = await this.arr('radarr', `/movie/lookup?term=tmdb:${encodeURIComponent(tmdbId)}`);
    if (!items[0]) throw new Error('Movie not found');
    return items[0];
  }

  async ensureMovie(tmdbId) {
    const existing = await this.arr('radarr', `/movie?tmdbId=${encodeURIComponent(tmdbId)}`);
    if (existing[0]) return existing[0];
    const movie = await this.movie(tmdbId);
    const profiles = await this.arr('radarr', '/qualityprofile');
    return this.arr('radarr', '/movie', { method: 'POST', body: JSON.stringify({ ...movie, qualityProfileId: profiles[0]?.id, rootFolderPath: '/data/library/movies', monitored: false, addOptions: { searchForMovie: false } }) });
  }

  async prepareMovieReleases(tmdbId, { force = false, freePublicDomain = false } = {}) {
    const result = await this.releaseCache.get(`movie:${tmdbId}`, async () => {
      const movie = await this.ensureMovie(tmdbId);
      const search = async signal => (await this.arr('radarr', `/release?movieId=${movie.id}`, { signal })).map(normalizeRelease);
      const releases = await partialSourceResults([
        { id: 'radarr', search },
      ], this.sourceTimeoutMs);
      return { ...releases, items: [...new Map(releases.items.map(release => [releaseIdentity(release), release])).values()] };
    }, { force });
    const items = freePublicDomain
      ? result.items.filter(release => release.sourceGroup === 'free_public_domain')
      : result.items;
    return { ...result, items, sources: { radarr: { ...result.sources.radarr, itemCount: items.length } }, prepared: true };
  }

  async releases(tmdbId, options = {}) {
    return (await this.prepareMovieReleases(tmdbId, options)).items;
  }

  async downloadRelease(tmdbId, selection) {
    await this.ensureMovie(tmdbId);
    const infoHash = infoHashFromReleaseGuid(selection.guid);
    if (infoHash) {
      const torrents = await this.qbit('/torrents/info');
      if ((torrents ?? []).some(torrent => String(torrent.hash).toLowerCase() === infoHash)) {
        return { accepted: true, duplicate: true, hash: infoHash };
      }
    }
    try {
      await this.arr('radarr', '/release', { method: 'POST', body: JSON.stringify({ guid: selection.guid, indexerId: selection.indexerId }) });
    } catch (error) {
      if (infoHash) {
        const torrents = await this.qbit('/torrents/info');
        if ((torrents ?? []).some(torrent => String(torrent.hash).toLowerCase() === infoHash)) {
          return { accepted: true, duplicate: true, hash: infoHash };
        }
      }
      const rejected = new Error('download_client_rejected');
      rejected.cause = error;
      throw rejected;
    }
    return { accepted: true, duplicate: false, hash: infoHash };
  }

  async qbitLogin({ signal } = {}) {
    if (this.qbitCookie) return this.qbitCookie;
    const body = new URLSearchParams({ username: this.config.qbitUser, password: this.config.qbitPassword });
    const response = await timedFetch(`${this.config.qbitUrl}/api/v2/auth/login`, { method: 'POST', body, signal, timeoutMs: this.sourceTimeoutMs });
    const text = await response.text();
    if (!loginSucceeded(response.status, text)) throw new Error('qBittorrent login failed');
    this.qbitCookie = response.headers.get('set-cookie')?.split(';')[0];
    return this.qbitCookie;
  }

  async qbit(path, options = {}) {
    const cookie = await this.qbitLogin({ signal: options.signal });
    const response = await timedFetch(`${this.config.qbitUrl}/api/v2${path}`, { ...options, timeoutMs: this.sourceTimeoutMs, headers: { cookie, ...(options.headers ?? {}) } });
    if (response.status === 403) { this.qbitCookie = null; throw new Error('qBittorrent session expired'); }
    if (!response.ok) throw new Error(`qBittorrent ${response.status}`);
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  async importedIds(category, { signal } = {}) {
    const service = category === 'series' ? 'sonarr' : 'radarr';
    try {
      return importedDownloadIds(await this.arr(service, '/history?page=1&pageSize=1000&sortKey=date&sortDirection=descending', { signal }));
    } catch (error) {
      if (signal?.aborted) throw error;
      return new Set();
    }
  }

  async isImported(hash, category, options = {}) {
    return (await this.importedIds(category, options)).has(String(hash).toLowerCase());
  }

  cachedImportedIds(category, { signal } = {}) {
    const cached = this.importedIdsCache.get(category);
    if ((!cached || cached.expiresAt <= Date.now()) && !this.importedIdsRefreshes.has(category)) {
      const refresh = this.importedIds(category, { signal })
        .then(ids => {
          if (!signal?.aborted) this.importedIdsCache.set(category, { ids, expiresAt: Date.now() + this.importedIdsCacheTtlMs });
        })
        .catch(() => null)
        .finally(() => this.importedIdsRefreshes.delete(category));
      this.importedIdsRefreshes.set(category, refresh);
    }
    return cached?.ids;
  }

  async downloads({ signal } = {}) {
    const torrents = (await this.qbit('/torrents/info', { signal })).map(normalizeTorrent);
    const categories = [...new Set(torrents
      .filter(torrent => torrent.progress >= 100)
      .map(torrent => torrent.category === 'series' ? 'series' : 'movies'))];
    const imported = new Map(categories.map(category => [category, this.cachedImportedIds(category, { signal })]));
    return torrents.map(torrent => {
      if (torrent.progress < 100) return { ...torrent, importStatus: 'downloading' };
      const category = torrent.category === 'series' ? 'series' : 'movies';
      if (!imported.get(category)) return { ...torrent, importStatus: 'checking_import', state: 'importing' };
      const importStatus = imported.get(category).has(String(torrent.hash).toLowerCase()) ? 'imported' : 'awaiting_import';
      return { ...torrent, importStatus, state: importStatus === 'awaiting_import' ? 'importing' : torrent.state };
    }).filter(torrent => torrent.importStatus !== 'imported');
  }
  async torrentAction(action, hash) {
    const endpoint = qbitActionEndpoint(action);
    const body = new URLSearchParams({ hashes: hash });
    if (action === 'delete') body.set('deleteFiles', 'true');
    return this.qbit(`/torrents/${endpoint}`, { method: 'POST', body });
  }

  bazarrKey() { return apiKeyFrom(this.config.bazarrConfig); }
  async bazarr(path, options = {}) {
    return jsonRequest(`${this.config.bazarrUrl}/api${path}`, { ...options, headers: { 'x-api-key': this.bazarrKey(), 'content-type': 'application/json', ...(options.headers ?? {}) } });
  }
  async subtitles(radarrId) { return this.bazarr(`/movies?radarrid[]=${encodeURIComponent(radarrId)}`); }
  async subtitleMedia() {
    const [movies, series] = await Promise.all([
      this.bazarr('/movies?start=0&length=-1'),
      this.arr('sonarr', '/series').catch(() => []),
    ]);
    const seriesGroups = await mapLimit((series ?? [])
      .filter(item => Number(item.statistics?.episodeFileCount ?? 0) > 0), 4, async item => {
      try {
        const result = await this.bazarr(`/episodes?seriesid[]=${encodeURIComponent(item.id)}`);
        const rows = (result?.data ?? result ?? []).filter(episode => episode.path);
        if (rows.length) return summarizeSubtitleSeries(item, rows, false);
      } catch {}
      const rows = await this.arr('sonarr', `/episode?seriesId=${encodeURIComponent(item.id)}&includeEpisodeFile=true`).catch(() => []);
      const imported = rows.filter(episode => episode.hasFile && episode.episodeFile?.path);
      return summarizeSubtitleSeries(item, imported, true);
    });
    return [
      ...(movies?.data ?? movies ?? []).map(normalizeSubtitleMedia),
      ...seriesGroups.filter(item => item.episodeCount > 0),
    ];
  }

  async subtitleSeason(seriesId, seasonNumber) {
    const [series, episodes, bazarrResult] = await Promise.all([
      this.arr('sonarr', `/series/${encodeURIComponent(seriesId)}`),
      this.arr('sonarr', `/episode?seriesId=${encodeURIComponent(seriesId)}&includeEpisodeFile=true`),
      this.bazarr(`/episodes?seriesid[]=${encodeURIComponent(seriesId)}`).catch(() => ({ data: [] })),
    ]);
    const bazarrById = new Map((bazarrResult?.data ?? bazarrResult ?? []).map(item => [Number(item.sonarrEpisodeId), item]));
    const poster = series.images?.find(image => image.coverType === 'poster')?.remoteUrl ?? null;
    return episodes
      .filter(episode => episode.hasFile && episode.episodeFile?.path && Number(episode.seasonNumber) === Number(seasonNumber))
      .map(episode => ({
        ...normalizeSubtitleEpisode({
          sonarrEpisodeId: episode.id,
          seriesTitle: series.title,
          episodeTitle: episode.title,
          seasonNumber: episode.seasonNumber,
          episodeNumber: episode.episodeNumber,
          year: series.year,
          path: episode.episodeFile.path,
          poster,
        }),
        hasVietnamese: hasVietnameseSubtitle(bazarrById.get(Number(episode.id))),
        episodeNumber: Number(episode.episodeNumber),
        seasonNumber: Number(episode.seasonNumber),
      }))
      .sort((left, right) => Number(left.hasVietnamese) - Number(right.hasVietnamese) || left.episodeNumber - right.episodeNumber);
  }

  async searchSeasonSubtitles(seriesId, seasonNumber) {
    const numericSeriesId = Number(seriesId);
    const numericSeasonNumber = Number(seasonNumber);
    const key = `${numericSeriesId}:${numericSeasonNumber}`;
    if (this.seasonSubtitleSearches.has(key)) return this.seasonSubtitleSearches.get(key);

    const pending = this.#searchSeasonSubtitles(numericSeriesId, numericSeasonNumber)
      .finally(() => this.seasonSubtitleSearches.delete(key));
    this.seasonSubtitleSearches.set(key, pending);
    return pending;
  }

  async #searchSeasonSubtitles(seriesId, seasonNumber) {
    const episodes = await this.subtitleSeason(seriesId, seasonNumber);
    const missing = episodes.filter(episode => !episode.hasVietnamese);
    const summary = {
      seriesId,
      seasonNumber,
      total: episodes.length,
      alreadyAvailable: episodes.length - missing.length,
      downloaded: 0,
      unavailable: 0,
      failed: 0,
    };
    let cursor = 0;
    const worker = async () => {
      while (cursor < missing.length) {
        const episode = missing[cursor++];
        try {
          const searchResult = await this.searchEpisodeSubtitles(episode.mediaId, 'vi');
          const candidates = [...(searchResult?.data ?? searchResult ?? [])]
            .sort((left, right) => Number(right.score ?? 0) - Number(left.score ?? 0));
          const best = candidates[0];
          if (!best) {
            summary.unavailable++;
            continue;
          }
          await this.downloadEpisodeSubtitle(episode.mediaId, best);
          await this.refreshEpisodeSubtitles(episode.mediaId).catch(() => null);
          summary.downloaded++;
        } catch {
          summary.failed++;
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(4, missing.length) }, worker));
    if (summary.downloaded > 0) await this.refreshJellyfin().catch(() => null);
    return summary;
  }

  async subtitleMovie(radarrId) {
    const result = await this.subtitles(radarrId);
    const movie = (result?.data ?? result ?? [])[0];
    if (!movie) throw new Error('Movie not found');
    return normalizeSubtitleMedia(movie);
  }
  async searchSubtitles(radarrId, language) {
    const result = await this.bazarr(`/providers/movies?radarrid=${encodeURIComponent(radarrId)}`);
    if (Array.isArray(result)) return filterSubtitleResults(result, language);
    return { ...result, data: filterSubtitleResults(result?.data ?? [], language) };
  }
  async searchAllSubtitles(radarrId) {
    return this.bazarr(`/providers/movies?radarrid=${encodeURIComponent(radarrId)}`);
  }
  async downloadSubtitle(radarrId, value) {
    return this.bazarr(`/providers/movies?${buildSubtitleDownloadQuery(radarrId, value)}`, { method: 'POST', body: '{}' });
  }
  async deleteSubtitle(radarrId, value) {
    return this.bazarr(`/movies/subtitles?${buildSubtitleDeleteQuery(radarrId, value)}`, { method: 'DELETE' });
  }
  async refreshSubtitles(radarrId) {
    return this.bazarr(`/movies?radarrid=${encodeURIComponent(radarrId)}&action=scan-disk`, { method: 'PATCH', body: '{}' });
  }
  async searchEpisodeSubtitles(episodeId, language) {
    const result = await this.bazarr(`/providers/episodes?episodeid=${encodeURIComponent(episodeId)}`);
    if (Array.isArray(result)) return filterSubtitleResults(result, language);
    return { ...result, data: filterSubtitleResults(result?.data ?? [], language) };
  }
  async searchAllEpisodeSubtitles(episodeId) {
    return this.bazarr(`/providers/episodes?episodeid=${encodeURIComponent(episodeId)}`);
  }
  async downloadEpisodeSubtitle(episodeId, value) {
    return this.bazarr(`/providers/episodes?${buildEpisodeSubtitleDownloadQuery(episodeId, value)}`, { method: 'POST', body: '{}' });
  }
  async refreshEpisodeSubtitles(episodeId) {
    return this.bazarr(`/episodes?episodeid=${encodeURIComponent(episodeId)}&action=scan-disk`, { method: 'PATCH', body: '{}' });
  }

  async refreshJellyfin({ signal } = {}) {
    if (!this.config.jellyfinApiKey) return null;
    const response = await timedFetch(`${this.config.jellyfinUrl}/Library/Refresh`, { method: 'POST', headers: { 'x-emby-token': this.config.jellyfinApiKey }, signal, timeoutMs: this.sourceTimeoutMs });
    if (!response.ok) throw new Error(`Jellyfin ${response.status}`);
    return null;
  }

  async jellyfin(pathname, options = {}) {
    if (!this.config.jellyfinApiKey) return null;
    return jsonRequest(`${this.config.jellyfinUrl}${pathname}`, { ...options, headers: { 'x-emby-token': this.config.jellyfinApiKey, 'content-type': 'application/json', ...(options.headers ?? {}) } });
  }

  async managedMovie(radarrId) {
    const movie = await this.arr('radarr', `/movie/${encodeURIComponent(radarrId)}`);
    const root = path.resolve(this.config.libraryRoot ?? '/data/library/movies');
    const moviePath = path.resolve(movie.path ?? '');
    const relative = path.relative(root, moviePath);
    if (!movie.path || relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Movie path is outside the managed library');
    return movie;
  }

  async localSubtitlesForMovie(movie) {
    const videoPath = movie.movieFile?.path;
    if (!videoPath) return [];
    const directory = path.dirname(videoPath);
    const stem = path.basename(videoPath, path.extname(videoPath));
    let entries = [];
    try { entries = await fsp.readdir(directory, { withFileTypes: true }); } catch { return []; }
    return entries.filter(entry => entry.isFile() && entry.name.startsWith(`${stem}.`) && /\.(srt|ass|ssa|vtt)$/i.test(entry.name)).map(entry => ({ id: subtitleIdFromName(entry.name), name: entry.name }));
  }

  async uploadLocalSubtitle(radarrId, value) {
    const movie = await this.managedMovie(radarrId);
    if (!movie.movieFile?.path) throw new Error('Movie file is unavailable');
    let upload;
    let name;
    try {
      upload = decodeSubtitleUpload(value);
      name = subtitleFileName(movie.movieFile.path, { ...value, extension: upload.extension });
    } catch (error) {
      error.code = 'invalid_request';
      throw error;
    }
    await fsp.writeFile(path.join(path.dirname(movie.movieFile.path), name), upload.buffer, { flag: value.replace ? 'w' : 'wx' });
    await this.refreshSubtitles(radarrId);
    await this.refreshJellyfin();
    return { id: subtitleIdFromName(name), name };
  }

  async managedSubtitles(radarrId) {
    return this.localSubtitlesForMovie(await this.managedMovie(radarrId));
  }

  async deleteLocalSubtitle(radarrId, subtitleId) {
    const movie = await this.managedMovie(radarrId);
    if (!movie.movieFile?.path) throw new Error('Movie file is unavailable');
    const name = subtitleNameFromId(subtitleId);
    await fsp.unlink(path.join(path.dirname(movie.movieFile.path), name));
    await this.refreshSubtitles(radarrId);
    await this.refreshJellyfin();
    return { deleted: true, id: subtitleId };
  }

  async deleteManagedMovie(radarrId) {
    await this.managedMovie(radarrId);
    const history = await this.arr('radarr', `/history?movieId=${encodeURIComponent(radarrId)}&pageSize=100`);
    const torrentHashes = [...new Set((history?.records ?? history ?? []).map(item => item.data?.torrentInfoHash?.toLowerCase()).filter(Boolean))];
    await this.arr('radarr', `/movie/${encodeURIComponent(radarrId)}?deleteFiles=true&addImportExclusion=false`, { method: 'DELETE' });
    try {
      for (const hash of torrentHashes) await this.torrentAction('delete', hash);
    } catch (error) {
      await this.refreshJellyfin();
      return { status: 'partial_failure', torrentHashes, error: 'Không thể xóa dữ liệu torrent' };
    }
    await this.refreshJellyfin();
    return { status: 'deleted', torrentHashes };
  }

  async library() {
    const [movies, series, jellyfin] = await Promise.all([
      this.arr('radarr', '/movie'),
      this.arr('sonarr', '/series').catch(() => []),
      this.jellyfin('/Items?Recursive=true&IncludeItemTypes=Movie,Series&Fields=Overview,Path,UserData,ProviderIds').then(value => value ?? { Items: [] }),
    ]);
    const jellyfinByPath = new Map((jellyfin.Items ?? []).map(item => [item.Path, item]));
    const movieItems = await mapLimit(movies.filter(movie => movie.hasFile !== false && movie.movieFile?.path), 8, async movie => {
      const item = jellyfinByPath.get(movie.movieFile.path);
      const subtitles = await this.localSubtitlesForMovie(movie);
      return normalizeLibraryMovie(movie, item, subtitles.length);
    });
    const seriesItems = series.filter(item => Number(item.statistics?.episodeFileCount ?? 0) > 0).map(item => {
      const jellyfinItem = jellyfinByPath.get(item.path);
      return normalizeLibrarySeries(item, jellyfinItem);
    });
    return [...movieItems, ...seriesItems];
  }
}
