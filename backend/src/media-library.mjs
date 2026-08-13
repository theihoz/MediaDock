import path from 'node:path';

const supportedSubtitleExtensions = new Set(['srt', 'ass', 'ssa', 'vtt']);
const maxSubtitleBytes = 5 * 1024 * 1024;

export class ImportStatusCache {
  constructor({ lookup, now = Date.now, importedTtlMs = 10 * 60 * 1000, pendingTtlMs = 3000 }) {
    this.lookup = lookup;
    this.now = now;
    this.importedTtlMs = importedTtlMs;
    this.pendingTtlMs = pendingTtlMs;
    this.values = new Map();
    this.inFlight = new Map();
  }

  async get(hash, category) {
    const key = `${category}:${String(hash).toLowerCase()}`;
    const cached = this.values.get(key);
    if (cached && cached.expiresAt > this.now()) return cached.status;
    if (this.inFlight.has(key)) return this.inFlight.get(key);
    const pending = Promise.resolve(this.lookup(hash, category)).then(imported => {
      const status = imported ? 'imported' : 'awaiting_import';
      const ttl = imported ? this.importedTtlMs : this.pendingTtlMs;
      this.values.set(key, { status, expiresAt: this.now() + ttl });
      return status;
    }).finally(() => this.inFlight.delete(key));
    this.inFlight.set(key, pending);
    return pending;
  }
}

export function normalizeLibraryMovie(movie, jellyfin, subtitleCount = 0) {
  const file = movie.movieFile ?? {};
  return {
    mediaId: movie.id,
    jellyfinId: jellyfin?.Id ?? null,
    title: movie.title ?? '',
    year: Number(movie.year ?? 0),
    poster: movie.images?.find(image => image.coverType === 'poster')?.remoteUrl ?? null,
    path: file.path ?? movie.path ?? '',
    watched: Boolean(jellyfin?.UserData?.Played),
    playbackPositionTicks: Number(jellyfin?.UserData?.PlaybackPositionTicks ?? 0),
    videoCodec: file.mediaInfo?.videoCodec ?? '',
    audioCodec: file.mediaInfo?.audioCodec ?? '',
    subtitleCount,
  };
}

export function decodeSubtitleUpload(value) {
  const extension = path.extname(String(value.fileName ?? '')).slice(1).toLowerCase();
  if (!supportedSubtitleExtensions.has(extension)) throw new Error('Định dạng phụ đề không được hỗ trợ');
  const buffer = Buffer.from(String(value.contentBase64 ?? ''), 'base64');
  if (buffer.length === 0) throw new Error('Phụ đề trống');
  if (buffer.length > maxSubtitleBytes) throw new Error('Phụ đề vượt quá 5 MB');
  return { extension, buffer };
}

export function subtitleFileName(videoPath, { language, forced = false, hearingImpaired = false, extension }) {
  if (!['vi', 'en'].includes(language)) throw new Error('Ngôn ngữ phụ đề không hợp lệ');
  if (!supportedSubtitleExtensions.has(extension)) throw new Error('Định dạng phụ đề không được hỗ trợ');
  const stem = path.basename(videoPath, path.extname(videoPath));
  const flags = [forced ? 'forced' : '', hearingImpaired ? 'hi' : ''].filter(Boolean);
  return `${stem}.${language}${flags.length ? `.${flags.join('.')}` : ''}.${extension}`;
}

export function subtitleIdFromName(name) {
  return Buffer.from(name, 'utf8').toString('base64url');
}

export function subtitleNameFromId(id) {
  const name = Buffer.from(String(id), 'base64url').toString('utf8');
  const extension = path.extname(name).slice(1).toLowerCase();
  if (!name || path.basename(name) !== name || !supportedSubtitleExtensions.has(extension)) throw new Error('Invalid subtitle id');
  return name;
}
