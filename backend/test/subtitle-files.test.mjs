import test from 'node:test';
import assert from 'node:assert/strict';

import { safeArchiveEntry, safeSubtitleName, validateSubtitlePayload } from '../src/subtitle-files.mjs';

test('derives language subtitle name from the video path', () => {
  assert.equal(safeSubtitleName('/data/Movie/Movie.1080p.mp4', 'vi', 'srt'), '/data/Movie/Movie.1080p.vi.srt');
});

test('rejects unsafe languages, formats, and oversized files', () => {
  assert.throws(() => safeSubtitleName('/data/Movie/file.mp4', '../vi', 'srt'), /invalid language/);
  assert.throws(() => safeSubtitleName('/data/Movie/file.mp4', 'vi', 'exe'), /unsupported format/);
  assert.throws(() => validateSubtitlePayload(Buffer.alloc(6 * 1024 * 1024), 'srt'), /subtitle too large/);
});

test('accepts supported non-empty subtitle payloads', () => {
  assert.equal(validateSubtitlePayload(Buffer.from('1\n00:00:00,000 --> 00:00:01,000\nHello'), 'srt'), true);
  assert.throws(() => validateSubtitlePayload(Buffer.alloc(0), 'srt'), /empty subtitle/);
});

test('accepts only flat supported subtitle entries from archives', () => {
  assert.equal(safeArchiveEntry('Movie.vi.srt'), 'Movie.vi.srt');
  assert.throws(() => safeArchiveEntry('../escape.srt'), /unsafe archive/);
  assert.throws(() => safeArchiveEntry('folder/file.srt'), /unsafe archive/);
  assert.throws(() => safeArchiveEntry('payload.exe'), /unsafe archive/);
});
