import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ImportStatusCache,
  decodeSubtitleUpload,
  normalizeLibraryMovie,
  subtitleFileName,
  subtitleIdFromName,
  subtitleNameFromId,
} from '../src/media-library.mjs';

test('caches imported status longer than an awaiting import', async () => {
  let now = 0;
  let calls = 0;
  const cache = new ImportStatusCache({ now: () => now, lookup: async hash => { calls++; return hash === 'done'; } });
  assert.equal(await cache.get('waiting', 'movies'), 'awaiting_import');
  now = 2000;
  assert.equal(await cache.get('waiting', 'movies'), 'awaiting_import');
  assert.equal(calls, 1);
  now = 3001;
  assert.equal(await cache.get('waiting', 'movies'), 'awaiting_import');
  assert.equal(calls, 2);
  assert.equal(await cache.get('done', 'movies'), 'imported');
  now += 599999;
  assert.equal(await cache.get('done', 'movies'), 'imported');
  assert.equal(calls, 3);
});

test('prunes expired import states and caps the cache', async () => {
  let now = 0;
  const cache = new ImportStatusCache({
    now: () => now,
    maxEntries: 2,
    lookup: async () => false,
  });

  await cache.get('a', 'movies');
  await cache.get('b', 'movies');
  await cache.get('c', 'movies');
  assert.deepEqual([...cache.values.keys()], ['movies:b', 'movies:c']);

  now = 3001;
  await cache.get('d', 'movies');
  assert.deepEqual([...cache.values.keys()], ['movies:d']);
});

test('normalizes a Radarr movie with its Jellyfin playback state', () => {
  assert.deepEqual(normalizeLibraryMovie({
    id: 11, title: 'The Batman', year: 2022, path: '/data/library/movies/The Batman (2022)',
    images: [{ coverType: 'poster', remoteUrl: 'https://image.test/poster.jpg' }],
    movieFile: { path: '/data/library/movies/The Batman (2022)/The Batman.mp4', mediaInfo: { videoCodec: 'h264', audioCodec: 'aac' } },
  }, { Id: 'jf-1', Path: '/data/library/movies/The Batman (2022)/The Batman.mp4', UserData: { Played: false, PlaybackPositionTicks: 42 } }, 3), {
    mediaId: 11, jellyfinId: 'jf-1', title: 'The Batman', year: 2022,
    poster: 'https://image.test/poster.jpg', path: '/data/library/movies/The Batman (2022)/The Batman.mp4',
    watched: false, playbackPositionTicks: 42, videoCodec: 'h264', audioCodec: 'aac', subtitleCount: 3,
  });
});

test('accepts bounded subtitle data and generates a safe sidecar name', () => {
  const upload = decodeSubtitleUpload({ fileName: 'download.srt', contentBase64: Buffer.from('1\n00:00:00,000 --> 00:00:01,000\nXin chào').toString('base64') });
  assert.equal(upload.extension, 'srt');
  assert.equal(upload.buffer.toString('utf8').includes('Xin chào'), true);
  assert.equal(subtitleFileName('/data/library/movies/Movie/Movie.mp4', { language: 'vi', forced: true, hearingImpaired: false, extension: 'srt' }), 'Movie.vi.forced.srt');
  assert.throws(() => decodeSubtitleUpload({ fileName: '../movie.exe', contentBase64: 'AA==' }), /định dạng phụ đề/i);
  assert.throws(() => decodeSubtitleUpload({ fileName: 'movie.srt', contentBase64: Buffer.alloc(5 * 1024 * 1024 + 1).toString('base64') }), /5 MB/);
});

test('subtitle ids cannot escape the movie directory', () => {
  const id = subtitleIdFromName('Movie.vi.srt');
  assert.equal(subtitleNameFromId(id), 'Movie.vi.srt');
  const traversal = Buffer.from('../Movie.mp4').toString('base64url');
  assert.throws(() => subtitleNameFromId(traversal), /subtitle id/);
});
