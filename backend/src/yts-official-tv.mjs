import crypto from 'node:crypto';

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
    const infoHash = infoHashFromMagnet(payload.magnetUrl);
    return { magnetUrl: payload.magnetUrl, title: payload.title, infoHash };
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
    return scope.episodeNumber === undefined
      ? exactSeason(row.title, scope.seasonNumber)
      : exactEpisode(row.title, scope.seasonNumber, scope.episodeNumber);
  });
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

export function normalizeTvTorrent(row, scope, secret, now = Date.now()) {
  const payload = { ...scope, title: row.title, magnetUrl: row.magnetUrl };
  return {
    downloadToken: createTvDownloadToken(payload, secret, now),
    title: row.title,
    size: Number(row.bytes ?? row.size ?? 0),
    seeders: Number(row.seeders ?? 0),
    peers: Number(row.peers ?? 0),
    quality: releaseQuality(row.title),
    codec: releaseCodec(row.title),
    source: 'YTS Official',
    rejected: false,
    rejections: [],
  };
}

export class YtsOfficialTvProvider {
  constructor({ baseUrl = 'https://en.yts-official.com/', secret, fetchImpl = fetch, timeoutMs = 15000, now = Date.now } = {}) {
    const url = new URL(baseUrl);
    if (url.protocol !== 'https:') throw new Error('YTS Official TV URL must use HTTPS');
    if (!secret) throw new Error('TV download token secret is required');
    this.baseUrl = url;
    this.secret = secret;
    this.fetchImpl = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.now = now;
  }

  async search(scope) {
    const url = new URL(this.baseUrl);
    url.search = new URLSearchParams({ api: 'torrents', mode: 'tv', name: scope.title, year: String(scope.year ?? ''), quality: 'all' });
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(url, { signal: controller.signal, headers: { accept: 'application/json' } });
      if (!response.ok || !String(response.headers.get('content-type') ?? '').toLowerCase().includes('application/json')) throw new TvProviderError('yts_tv_provider_unavailable');
      const text = await response.text();
      if (Buffer.byteLength(text) > MAX_RESPONSE_BYTES) throw new TvProviderError('yts_tv_provider_unavailable');
      const data = JSON.parse(text);
      const rows = filterTvTorrents(data.hits, scope);
      if (rows.length === 0) throw new TvProviderError('yts_tv_release_unavailable');
      return rows.map(row => normalizeTvTorrent(row, scope, this.secret, this.now()));
    } catch (error) {
      if (error instanceof TvProviderError) throw error;
      throw new TvProviderError('yts_tv_provider_unavailable');
    } finally {
      clearTimeout(timer);
    }
  }

  resolveToken(token, expectedScope) {
    return verifyTvDownloadToken(token, this.secret, expectedScope, this.now());
  }
}
