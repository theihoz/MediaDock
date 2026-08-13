import crypto from 'node:crypto';
import { JsonTrendingStore } from './trending-movies.mjs';

const TOKEN_TTL_MS = 5 * 60 * 1000;
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;

export class TvProviderError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function hmac(value, secret) {
  return crypto.createHmac('sha256', secret).update(value).digest('base64url');
}

function safeEqual(left, right) {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function infoHashFromMagnet(magnetUrl) {
  let value;
  try { value = new URL(magnetUrl).searchParams.get('xt') ?? ''; } catch { throw new TvProviderError('invalid_download_token'); }
  const match = value.match(/^urn:btih:([a-f0-9]{40})$/i);
  if (!match) throw new TvProviderError('invalid_download_token');
  return match[1].toLowerCase();
}

function scopeMatches(payload, expected) {
  return Number(payload.tvdbId) === Number(expected.tvdbId) &&
    Number(payload.seasonNumber) === Number(expected.seasonNumber) &&
    (expected.episodeNumber === undefined
      ? payload.episodeNumber === undefined
      : Number(payload.episodeNumber) === Number(expected.episodeNumber));
}

export function createTvDownloadToken(payload, secret, now = Date.now()) {
  const encoded = Buffer.from(JSON.stringify({ ...payload, expiresAt: now + TOKEN_TTL_MS })).toString('base64url');
  return `${encoded}.${hmac(encoded, secret)}`;
}

export function verifyTvDownloadToken(token, secret, expectedScope, now = Date.now()) {
  try {
    const [encoded, signature, extra] = String(token).split('.');
    if (!encoded || !signature || extra || !safeEqual(signature, hmac(encoded, secret))) throw new Error('signature');
    const payload = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
    if (Number(payload.expiresAt) < now || !scopeMatches(payload, expectedScope)) throw new Error('scope');
    if (payload.sourceMode === 'prowlarr') {
      if (!payload.guid || !Number.isInteger(Number(payload.indexerId))) throw new Error('fallback');
      return { sourceMode: 'prowlarr', guid: payload.guid, indexerId: Number(payload.indexerId), title: payload.title, infoHash: null };
    }
    const infoHash = infoHashFromMagnet(payload.magnetUrl);
    return { sourceMode: 'yts', magnetUrl: payload.magnetUrl, title: payload.title, infoHash };
  } catch (error) {
    if (error instanceof TvProviderError) throw error;
    throw new TvProviderError('invalid_download_token');
  }
}

function exactSeason(title, seasonNumber) {
  const season = Number(seasonNumber);
  const padded = String(season).padStart(2, '0');
  if (/S\d{1,2}\s*[-–]\s*S\d{1,2}/i.test(title) || /S\d{1,2}\s*(?:to|through)\s*S\d{1,2}/i.test(title)) return false;
  if (/S\d{1,2}E\d{1,3}|\b\d{1,2}x\d{1,3}\b/i.test(title)) return false;
  return new RegExp(`(?:\\bS(?:${padded}|${season})\\b|\\bSeason[ ._-]*0?${season}\\b)`, 'i').test(title);
}

function exactEpisode(title, seasonNumber, episodeNumber) {
  const season = Number(seasonNumber);
  const episode = Number(episodeNumber);
  const s = String(season).padStart(2, '0');
  const e = String(episode).padStart(2, '0');
  return new RegExp(`(?:\\bS(?:${s}|${season})E(?:${e}|${episode})\\b|\\b0?${season}x0?${episode}\\b)`, 'i').test(title);
}

export function filterTvTorrents(rows, scope) {
  return (Array.isArray(rows) ? rows : []).filter(row => {
    if (!row?.title || typeof row.magnetUrl !== 'string' || !row.magnetUrl.startsWith('magnet:?')) return false;
    return matchesTvTitleScope(row.title, scope);
  });
}

export function matchesTvTitleScope(title, scope) {
  return scope.episodeNumber === undefined
    ? exactSeason(title, scope.seasonNumber)
    : exactEpisode(title, scope.seasonNumber, scope.episodeNumber);
}

function releaseQuality(title) {
  if (/2160p|4K|UHD/i.test(title)) return '2160p';
  if (/1080p/i.test(title)) return '1080p';
  if (/720p/i.test(title)) return '720p';
  return 'Unknown';
}

function releaseCodec(title) {
  if (/(?:x|h)[ ._-]?265|HEVC/i.test(title)) return 'H.265';
  if (/AV1/i.test(title)) return 'AV1';
  if (/(?:x|h)[ ._-]?264|AVC/i.test(title)) return 'H.264';
  return 'Unknown';
}

function normalizeTvDiscovery(value) {
  const date = value.first_air_date ?? value.firstAirDate ?? '';
  const poster = value.poster_path ?? value.posterPath;
  const providerId = Number(value.id ?? value.providerId ?? 0);
  return {
    mediaType: 'series',
    providerId,
    tvdbId: Number.isFinite(Number(value.tvdbId)) && Number(value.tvdbId) > 0 ? Number(value.tvdbId) : null,
    title: value.name ?? value.title ?? '',
    year: /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : Number(value.year ?? 0) || null,
    overview: value.overview ?? '',
    poster: poster ? `https://image.tmdb.org/t/p/w500${poster}` : null,
    rating: Number(value.vote_average ?? value.rating ?? 0),
    inLibrary: false,
  };
}

export function normalizeTvTorrent(row, scope, secret, now = Date.now()) {
  const payload = { ...scope, sourceMode: 'yts', title: row.title, magnetUrl: row.magnetUrl };
  return {
    downloadToken: createTvDownloadToken(payload, secret, now),
    title: row.title,
    size: Number(row.bytes ?? row.size ?? 0),
    seeders: Number(row.seeders ?? 0),
    peers: Number(row.peers ?? 0),
    quality: releaseQuality(row.title),
    codec: releaseCodec(row.title),
    source: 'YTS Official',
    sourceMode: 'yts',
    fallbackUsed: false,
    rejected: false,
    rejections: [],
  };
}

export function normalizeSonarrTvRelease(row, scope, secret, now = Date.now()) {
  const payload = { ...scope, sourceMode: 'prowlarr', title: row.title, guid: row.guid, indexerId: Number(row.indexerId) };
  return {
    downloadToken: createTvDownloadToken(payload, secret, now),
    title: row.title ?? '',
    size: Number(row.size ?? 0),
    seeders: Number(row.seeders ?? 0),
    peers: Number(row.peers ?? 0),
    quality: row.quality?.quality?.name ?? releaseQuality(row.title ?? ''),
    codec: releaseCodec(row.title ?? ''),
    source: row.indexer ?? row.indexerName ?? 'Prowlarr',
    sourceMode: 'prowlarr',
    fallbackUsed: true,
    rejected: Boolean(row.rejected ?? row.rejections?.length),
    rejections: row.rejections ?? [],
  };
}

export class YtsOfficialTvProvider {
  constructor({ baseUrl = 'https://en.yts-official.com/', secret, fetchImpl = fetch, timeoutMs = 15000, now = Date.now, store, cachePath = '/data/cache/trending-tv.json' } = {}) {
    const url = new URL(baseUrl);
    if (url.protocol !== 'https:') throw new Error('YTS Official TV URL must use HTTPS');
    if (!secret) throw new Error('TV download token secret is required');
    this.baseUrl = url;
    this.secret = secret;
    this.fetchImpl = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.now = now;
    this.store = store ?? new JsonTrendingStore(cachePath);
    this.trendingFlight = null;
  }

  async request(params) {
    const url = new URL(this.baseUrl);
    url.search = new URLSearchParams(params);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(url, { signal: controller.signal, headers: { accept: 'application/json' } });
      if (!response.ok || !String(response.headers.get('content-type') ?? '').toLowerCase().includes('application/json')) throw new TvProviderError('yts_tv_provider_unavailable');
      const text = await response.text();
      if (Buffer.byteLength(text) > MAX_RESPONSE_BYTES) throw new TvProviderError('yts_tv_provider_unavailable');
      return JSON.parse(text);
    } catch (error) {
      if (error instanceof TvProviderError) throw error;
      throw new TvProviderError('yts_tv_provider_unavailable');
    } finally { clearTimeout(timer); }
  }

  async search(scope) {
    try {
      const data = await this.request({ api: 'torrents', mode: 'tv', name: scope.title, year: String(scope.year ?? ''), quality: 'all' });
      const rows = filterTvTorrents(data.hits, scope);
      if (rows.length === 0) throw new TvProviderError('yts_tv_release_unavailable');
      return rows.map(row => normalizeTvTorrent(row, scope, this.secret, this.now()));
    } catch (error) {
      if (error instanceof TvProviderError) throw error;
      throw new TvProviderError('yts_tv_provider_unavailable');
    } finally {}
  }

  async trending() {
    if (this.trendingFlight) return this.trendingFlight;
    this.trendingFlight = this.loadTrending().finally(() => { this.trendingFlight = null; });
    return this.trendingFlight;
  }

  async loadTrending() {
    for (const [type, source] of [['trending', 'yts_official'], ['popular', 'popular']]) {
      try {
        const data = await this.request({ api: type, mode: 'tv', page: '1', sort: 'popularity.desc' });
        const items = (data.results ?? []).map(normalizeTvDiscovery).filter(item => item.providerId > 0 && item.title).slice(0, 40);
        if (items.length) {
          await this.store.write(items);
          return { items, stale: false, source };
        }
      } catch {}
    }
    const items = await this.store.read();
    if (items.length) return { items, stale: true, source: 'cache' };
    return { items: [], stale: false, source: 'unavailable' };
  }

  resolveToken(token, expectedScope) {
    return verifyTvDownloadToken(token, this.secret, expectedScope, this.now());
  }

  normalizeSonarr(row, scope) {
    return normalizeSonarrTvRelease(row, scope, this.secret, this.now());
  }
}
