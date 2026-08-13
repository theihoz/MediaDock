import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { decodeSubtitleUpload, ImportStatusCache, normalizeLibraryMovie, subtitleFileName, subtitleIdFromName, subtitleNameFromId } from './media-library.mjs';

export function extractApiKey(text) {
  const match = text.match(/<ApiKey>([^<]+)<\/ApiKey>/i) ?? text.match(/^\s*apikey:\s*['"]?([^'"\s]+)['"]?\s*$/im);
  if (!match) throw new Error('API key not found');
  return match[1];
}

export function apiKeyFrom(path) {
  return extractApiKey(fs.readFileSync(path, 'utf8'));
}

export function normalizeRelease(value) {
  const title = value.title ?? '';
  const codec = /(?:x|h)[ ._-]?265|hevc/i.test(title) ? 'H.265' : /av1/i.test(title) ? 'AV1' : /(?:x|h)[ ._-]?264|avc/i.test(title) ? 'H.264' : 'Unknown';
  const rejections = value.rejections ?? [];
  const onlyNeedsMonitoring = rejections.length > 0 && rejections.every(reason => /^Episode wasn't requested:/i.test(reason));
  return {
    guid: value.guid,
    indexerId: value.indexerId,
    title,
    size: value.size ?? 0,
    seeders: value.seeders ?? 0,
    peers: value.peers ?? 0,
    quality: value.quality?.quality?.name ?? 'Unknown',
    resolution: value.quality?.quality?.resolution ?? 0,
    codec,
    rejected: onlyNeedsMonitoring ? false : Boolean(value.rejected ?? rejections.length),
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

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  if (!response.ok) throw new Error(`${response.status} ${text.slice(0, 240)}`);
  return text ? JSON.parse(text) : null;
}

export class ReleaseSearchCache {
  constructor({ ttlMs = 10 * 60 * 1000, timeoutMs = 15000, now = Date.now } = {}) {
    this.ttlMs = ttlMs;
    this.timeoutMs = timeoutMs;
    this.now = now;
    this.values = new Map();
    this.inFlight = new Map();
  }

  async get(key, search) {
    const cached = this.values.get(key);
    if (cached && cached.expiresAt > this.now()) return cached.value;
    if (this.inFlight.has(key)) return this.inFlight.get(key);

    const pending = this.withTimeout(search()).then(value => {
      this.values.set(key, { value, expiresAt: this.now() + this.ttlMs });
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
          timer = setTimeout(() => reject(new Error('Tìm bản tải quá 15 giây. Hãy kiểm tra YTS trong Prowlarr rồi thử lại.')), this.timeoutMs);
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
    this.qbitCookie = null;
    this.releaseCache = config.releaseCache ?? new ReleaseSearchCache();
    this.importStatusCache = config.importStatusCache ?? new ImportStatusCache({ lookup: (hash, category) => this.isImported(hash, category) });
  }

  arrKey(name) { return apiKeyFrom(this.config[`${name}Config`]); }
  arrUrl(name, path) { return `${this.config[`${name}Url`]}/api/v3${path}`; }

  async arr(name, path, options = {}) {
    return jsonRequest(this.arrUrl(name, path), {
      ...options,
      headers: { 'x-api-key': this.arrKey(name), 'content-type': 'application/json', ...(options.headers ?? {}) },
    });
  }

  async searchMovies(term) {
    const items = await this.arr('radarr', `/movie/lookup?term=${encodeURIComponent(term)}`);
    return items.map(item => ({ tmdbId: item.tmdbId, title: item.title, year: item.year, overview: item.overview, poster: item.remotePoster, runtime: item.runtime, genres: item.genres ?? [], inLibrary: Boolean(item.id) }));
  }

  normalizeSeries(item) {
    return { mediaType: 'series', tvdbId: item.tvdbId, title: item.title, year: item.year, overview: item.overview, poster: item.remotePoster, inLibrary: Boolean(item.id), seasons: item.seasons ?? [] };
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
    return (await this.arr('sonarr', `/episode?seriesId=${series.id}`)).map(item => ({ episodeId: item.id, seasonNumber: item.seasonNumber, episodeNumber: item.episodeNumber, title: item.title, airDate: item.airDate, hasFile: Boolean(item.hasFile) }));
  }

  async seriesReleases(tvdbId, selection) {
    const series = await this.ensureSeries(tvdbId);
    const cacheKey = selection.episodeId ? `series:${tvdbId}:episode:${selection.episodeId}` : `series:${tvdbId}:season:${selection.seasonNumber}`;
    return this.releaseCache.get(cacheKey, async () => {
      if (!this.tvProvider) throw new Error('yts_tv_provider_unavailable');
      if (selection.episodeId) {
        const episode = await this.arr('sonarr', `/episode/${encodeURIComponent(selection.episodeId)}`);
        return this.tvProvider.search({ tvdbId: Number(tvdbId), title: series.title, year: series.year, seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber });
      }
      return this.tvProvider.search({ tvdbId: Number(tvdbId), title: series.title, year: series.year, seasonNumber: Number(selection.seasonNumber) });
    });
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
    const torrents = await this.qbit('/torrents/info');
    if ((torrents ?? []).some(torrent => String(torrent.hash).toLowerCase() === release.infoHash)) {
      return { accepted: true, duplicate: true, hash: release.infoHash };
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
      await this.qbit('/torrents/add', { method: 'POST', body: new URLSearchParams({ urls: release.magnetUrl, category: 'series' }) });
    } catch {
      const error = new Error('download_client_rejected');
      error.code = 'download_client_rejected';
      throw error;
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

  async releases(tmdbId) {
    return this.releaseCache.get(String(tmdbId), async () => {
      const movie = await this.ensureMovie(tmdbId);
      return (await this.arr('radarr', `/release?movieId=${movie.id}`)).map(normalizeRelease);
    });
  }

  async downloadRelease(tmdbId, selection) {
    await this.ensureMovie(tmdbId);
    return this.arr('radarr', '/release', { method: 'POST', body: JSON.stringify({ guid: selection.guid, indexerId: selection.indexerId }) });
  }

  async qbitLogin() {
    if (this.qbitCookie) return this.qbitCookie;
    const body = new URLSearchParams({ username: this.config.qbitUser, password: this.config.qbitPassword });
    const response = await fetch(`${this.config.qbitUrl}/api/v2/auth/login`, { method: 'POST', body });
    const text = await response.text();
    if (!loginSucceeded(response.status, text)) throw new Error('qBittorrent login failed');
    this.qbitCookie = response.headers.get('set-cookie')?.split(';')[0];
    return this.qbitCookie;
  }

  async qbit(path, options = {}) {
    const cookie = await this.qbitLogin();
    const response = await fetch(`${this.config.qbitUrl}/api/v2${path}`, { ...options, headers: { cookie, ...(options.headers ?? {}) } });
    if (response.status === 403) { this.qbitCookie = null; throw new Error('qBittorrent session expired'); }
    if (!response.ok) throw new Error(`qBittorrent ${response.status}`);
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  async isImported(hash, category) {
    const service = category === 'series' ? 'sonarr' : 'radarr';
    try {
      const history = await this.arr(service, '/history?pageSize=100&sortKey=date&sortDirection=descending');
      const expected = String(hash).toLowerCase();
      return (history?.records ?? history ?? []).some(item =>
        item.eventType === 'downloadFolderImported' &&
        String(item.downloadId ?? item.data?.downloadId ?? '').toLowerCase() === expected);
    } catch {
      return false;
    }
  }
  async downloads() {
    const torrents = (await this.qbit('/torrents/info')).map(normalizeTorrent);
    const resolved = await Promise.all(torrents.map(async torrent => {
      if (torrent.progress < 100) return { ...torrent, importStatus: 'downloading' };
      const importStatus = await this.importStatusCache.get(torrent.hash, torrent.category);
      return { ...torrent, importStatus, state: importStatus === 'awaiting_import' ? 'importing' : torrent.state };
    }));
    return resolved.filter(torrent => torrent.importStatus !== 'imported');
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
    const result = await this.bazarr('/movies?start=0&length=-1');
    return (result?.data ?? result ?? []).map(normalizeSubtitleMedia);
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
  async downloadSubtitle(radarrId, value) {
    return this.bazarr(`/providers/movies?${buildSubtitleDownloadQuery(radarrId, value)}`, { method: 'POST', body: '{}' });
  }
  async deleteSubtitle(radarrId, value) {
    return this.bazarr(`/movies/subtitles?${buildSubtitleDeleteQuery(radarrId, value)}`, { method: 'DELETE' });
  }
  async refreshSubtitles(radarrId) {
    return this.bazarr(`/movies?radarrid=${encodeURIComponent(radarrId)}&action=scan-disk`, { method: 'PATCH', body: '{}' });
  }

  async refreshJellyfin() {
    if (!this.config.jellyfinApiKey) return null;
    const response = await fetch(`${this.config.jellyfinUrl}/Library/Refresh`, { method: 'POST', headers: { 'x-emby-token': this.config.jellyfinApiKey } });
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
    const upload = decodeSubtitleUpload(value);
    const name = subtitleFileName(movie.movieFile.path, { ...value, extension: upload.extension });
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
    const movies = await this.arr('radarr', '/movie');
    const jellyfin = await this.jellyfin('/Items?Recursive=true&IncludeItemTypes=Movie&Fields=Overview,Path,UserData,ProviderIds') ?? { Items: [] };
    return Promise.all(movies.filter(movie => movie.hasFile !== false && movie.movieFile?.path).map(async movie => {
      const item = (jellyfin.Items ?? []).find(value => value.Path === movie.movieFile.path);
      const subtitles = await this.localSubtitlesForMovie(movie);
      return normalizeLibraryMovie(movie, item, subtitles.length);
    }));
  }
}
