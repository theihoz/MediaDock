import fs from 'node:fs';

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
    rejected: Boolean(value.rejected ?? value.rejections?.length),
    rejections: value.rejections ?? [],
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

export class MediaClients {
  constructor(config) { this.config = config; this.qbitCookie = null; }

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
    const movie = await this.ensureMovie(tmdbId);
    return (await this.arr('radarr', `/release?movieId=${movie.id}`)).map(normalizeRelease);
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

  async downloads() { return (await this.qbit('/torrents/info')).map(normalizeTorrent); }
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

  async library() {
    if (!this.config.jellyfinApiKey) return [];
    return jsonRequest(`${this.config.jellyfinUrl}/Items?Recursive=true&IncludeItemTypes=Movie&Fields=Overview,Path,UserData`, { headers: { 'x-emby-token': this.config.jellyfinApiKey } });
  }
}
