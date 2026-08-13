import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildSubtitleDeleteQuery,
  buildSubtitleDownloadQuery,
  filterSubtitleResults,
  extractApiKey,
  loginSucceeded,
  normalizeRelease,
  normalizeTorrent,
  normalizeSubtitleMedia,
  qbitActionEndpoint,
  ReleaseSearchCache,
} from '../src/media-clients.mjs';

test('coalesces release searches and caches the result until the ttl expires', async () => {
  let calls = 0;
  let now = 1000;
  let resolveSearch;
  const cache = new ReleaseSearchCache({ ttlMs: 600000, timeoutMs: 15000, now: () => now });
  const search = () => {
    calls += 1;
    return new Promise(resolve => { resolveSearch = resolve; });
  };

  const first = cache.get('603', search);
  const concurrent = cache.get('603', search);
  assert.equal(calls, 1);
  resolveSearch([{ guid: 'matrix' }]);
  assert.deepEqual(await first, [{ guid: 'matrix' }]);
  assert.deepEqual(await concurrent, [{ guid: 'matrix' }]);
  assert.deepEqual(await cache.get('603', search), [{ guid: 'matrix' }]);
  assert.equal(calls, 1);

  now += 600001;
  const expired = cache.get('603', search);
  assert.equal(calls, 2);
  resolveSearch([{ guid: 'matrix-2' }]);
  assert.deepEqual(await expired, [{ guid: 'matrix-2' }]);
});

test('fails a release search with a useful timeout error', async () => {
  const cache = new ReleaseSearchCache({ ttlMs: 600000, timeoutMs: 5 });
  await assert.rejects(cache.get('414906', () => new Promise(() => {})), /15 giây/);
});

test('extracts an arr API key without exposing other XML settings', () => {
  assert.equal(extractApiKey('<Config><ApiKey>abc123</ApiKey><Password>hidden</Password></Config>'), 'abc123');
  assert.throws(() => extractApiKey('<Config />'), /API key not found/);
});

test('normalizes a Radarr release for the desktop client', () => {
  assert.deepEqual(normalizeRelease({
    guid: 'g', indexerId: 7, title: 'Movie.2026.1080p.WEB-DL.x265', size: 1500,
    seeders: 22, peers: 4, quality: { quality: { name: 'WEBDL-1080p', resolution: 1080 } },
    rejections: ['Not preferred'],
  }), {
    guid: 'g', indexerId: 7, title: 'Movie.2026.1080p.WEB-DL.x265', size: 1500,
    seeders: 22, peers: 4, quality: 'WEBDL-1080p', resolution: 1080,
    codec: 'H.265', rejected: true, rejections: ['Not preferred'],
  });
});

test('normalizes qBittorrent data without leaking tracker credentials', () => {
  const torrent = normalizeTorrent({ hash: 'h', name: 'Movie', progress: .5, dlspeed: 10, eta: 20, size: 30, state: 'downloading', tracker: 'https://user:pass@example.test' });
  assert.equal(torrent.progress, 50);
  assert.equal('tracker' in torrent, false);
});

test('accepts both legacy and current qBittorrent login responses', () => {
  assert.equal(loginSucceeded(200, 'Ok.'), true);
  assert.equal(loginSucceeded(204, ''), true);
  assert.equal(loginSucceeded(200, 'Fails.'), false);
});

test('limits Bazarr manual search results to the requested language', () => {
  assert.deepEqual(
    filterSubtitleResults([
      { language: 'vi', provider: 'gestdown' },
      { language: 'en', provider: 'yifysubtitles' },
    ], 'vi'),
    [{ language: 'vi', provider: 'gestdown' }],
  );
});

test('builds the Bazarr subtitle download contract from a search result', () => {
  assert.equal(
    buildSubtitleDownloadQuery(42, {
      provider: 'gestdown', subtitle: 'encoded-subtitle', hi: true,
      forced: false, originalFormat: true,
    }),
    'radarrid=42&hi=true&forced=false&original_format=true&provider=gestdown&subtitle=encoded-subtitle',
  );
});

test('builds the complete Bazarr subtitle delete contract', () => {
  assert.equal(
    buildSubtitleDeleteQuery(42, {
      language: 'vi', forced: false, hi: false, path: '/data/movie.vi.srt',
    }),
    'radarrid=42&language=vi&forced=false&hi=false&path=%2Fdata%2Fmovie.vi.srt',
  );
  assert.throws(() => buildSubtitleDeleteQuery(42, { language: 'vi' }), /path is required/);
});

test('uses qBittorrent v5 stop/start action names', () => {
  assert.equal(qbitActionEndpoint('pause'), 'stop');
  assert.equal(qbitActionEndpoint('resume'), 'start');
  assert.equal(qbitActionEndpoint('retry'), 'start');
  assert.equal(qbitActionEndpoint('delete'), 'delete');
});

test('normalizes Bazarr movies for the Flutter selector', () => {
  assert.deepEqual(normalizeSubtitleMedia({ radarrId: 7, title: 'Movie', year: '2020', path: '/data/library/movies/Movie/file.mp4', imdbId: 'tt7', poster: '/poster.jpg' }), {
    mediaId: 7, title: 'Movie', year: 2020, path: '/data/library/movies/Movie/file.mp4', imdbId: 'tt7', poster: '/poster.jpg', type: 'movie',
  });
});
