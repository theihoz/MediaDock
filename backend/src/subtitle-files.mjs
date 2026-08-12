import path from 'node:path';

const formats = new Set(['srt', 'vtt', 'ass']);

export function safeSubtitleName(videoPath, language, format) {
  if (!/^(vi|en)$/.test(String(language))) throw new Error('invalid language');
  const extension = String(format).replace(/^\./, '').toLowerCase();
  if (!formats.has(extension)) throw new Error('unsupported format');
  const parsed = path.posix.parse(videoPath);
  if (!parsed.dir || !parsed.name) throw new Error('invalid video path');
  return path.posix.join(parsed.dir, `${parsed.name}.${language}.${extension}`);
}

export function validateSubtitlePayload(buffer, format, maxBytes = 5 * 1024 * 1024) {
  const extension = String(format).replace(/^\./, '').toLowerCase();
  if (!formats.has(extension)) throw new Error('unsupported format');
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) throw new Error('empty subtitle');
  if (buffer.length > maxBytes) throw new Error('subtitle too large');
  return true;
}

export function safeArchiveEntry(name) {
  const normalized = String(name).replace(/\\/g, '/');
  const extension = path.posix.extname(normalized).slice(1).toLowerCase();
  if (!normalized || normalized !== path.posix.basename(normalized) || normalized.includes('..') || !formats.has(extension)) throw new Error('unsafe archive');
  return normalized;
}
