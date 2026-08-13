import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import {
  buildSubtitleDeleteQuery,
  buildSubtitleDownloadQuery,
  filterSubtitleResults,
  extractApiKey,
  loginSucceeded,
  MediaClients,
  normalizeRelease,
  normalizeTorrent,
  normalizeSubtitleEpisode,
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

test('keeps a manually selected Sonarr release actionable when only monitoring is missing', () => {
  const release = normalizeRelease({
    guid: 'g', indexerId: 2, title: 'Show S01E01 1080p',
    rejected: true, rejections: ["Episode wasn't requested: 1x1"],
  });
  assert.equal(release.rejected, false);
  assert.deepEqual(release.rejections, ["Episode wasn't requested: 1x1"]);
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

test('normalizes Bazarr episodes for the same subtitle selector', () => {
  assert.deepEqual(normalizeSubtitleEpisode({ sonarrEpisodeId: 91, seriesTitle: 'Show', episodeTitle: 'Pilot', season: 1, episode: 2, path: '/series/show.mkv' }), {
    mediaId: 91, title: 'Show S01E02 • Pilot', year: 0, path: '/series/show.mkv', imdbId: null, poster: null, type: 'episode',
  });
});

test('hides only completed torrents confirmed as imported', async () => {
  const media = new MediaClients({
    importStatusCache: { get: async hash => hash === 'done' ? 'imported' : 'awaiting_import' },
  });
  media.qbit = async () => [
    { hash: 'active', name: 'Active', progress: .5, state: 'downloading', category: 'movies' },
    { hash: 'waiting', name: 'Waiting', progress: 1, state: 'stalledUP', category: 'movies' },
    { hash: 'done', name: 'Done', progress: 1, state: 'forcedUP', category: 'movies' },
  ];

  assert.deepEqual((await media.downloads()).map(item => [item.hash, item.importStatus, item.state]), [
    ['active', 'downloading', 'downloading'],
    ['waiting', 'awaiting_import', 'importing'],
  ]);
});

test('matches Arr import history by download hash without relying on its broken filter', async () => {
  const media = new MediaClients({});
  let requestPath;
  media.arr = async (_service, path) => {
    requestPath = path;
    return { records: [{ eventType: 'downloadFolderImported', downloadId: 'ABC123' }] };
  };
  assert.equal(await media.isImported('abc123', 'movies'), true);
  assert.match(requestPath, /pageSize=100/);
  assert.doesNotMatch(requestPath, /downloadId=/);
});

test('searches and normalizes Sonarr series by TVDB id', async () => {
  const media = new MediaClients({});
  media.arr = async (_service, requestPath) => {
    assert.equal(requestPath, '/series/lookup?term=batman');
    return [{ tvdbId: 123, title: 'Batman', year: 2024, overview: 'Series', remotePoster: 'poster.jpg', seasons: [{ seasonNumber: 1 }] }];
  };
  assert.deepEqual(await media.searchSeries('batman'), [{ mediaType: 'series', tvdbId: 123, title: 'Batman', year: 2024, overview: 'Series', poster: 'poster.jpg', inLibrary: false, seasons: [{ seasonNumber: 1 }] }]);
});

test('uses YTS releases without calling Sonarr fallback', async () => {
  const searches = [];
  const media = new MediaClients({ tvProvider: { search: async scope => { searches.push(scope); return [{ downloadToken: 'token' }]; } } });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024 });
  media.arr = async (_service, requestPath) => {
    if (requestPath === '/episode?seriesId=7') return [{ id: 91, seasonNumber: 1, episodeNumber: 2, title: 'Two', hasFile: false }];
    if (requestPath === '/episode/91') return { id: 91, seasonNumber: 1, episodeNumber: 2 };
    throw new Error(requestPath);
  };
  assert.equal((await media.seriesEpisodes(123))[0].episodeId, 91);
  await media.seriesReleases(123, { seasonNumber: 1 });
  await media.seriesReleases(123, { episodeId: 91 });
  assert.deepEqual(searches, [
    { tvdbId: 123, title: 'Show', year: 2024, seasonNumber: 1 },
    { tvdbId: 123, title: 'Show', year: 2024, seasonNumber: 1, episodeNumber: 2 },
  ]);
});

test('falls back to exact Sonarr season packs when YTS has no release', async () => {
  const media = new MediaClients({ tvProvider: {
    search: async () => { throw new Error('yts_tv_release_unavailable'); },
    normalizeSonarr: (row, scope) => ({ title: row.title, source: row.indexer, sourceMode: 'prowlarr', fallbackUsed: true, scope }),
  } });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024 });
  media.arr = async (_service, requestPath) => {
    assert.equal(requestPath, '/release?seriesId=7&seasonNumber=2');
    return [
      { title: 'Show S02 pack', guid: 'g1', indexerId: 1, indexer: 'EZTV', fullSeason: true, seasonNumber: 2 },
      { title: 'Show S02E01', guid: 'g2', indexerId: 2, indexer: 'Other', fullSeason: false, seasonNumber: 2 },
      { title: 'Show S03 pack', guid: 'g3', indexerId: 2, indexer: 'Other', fullSeason: true, seasonNumber: 3 },
    ];
  };
  const releases = await media.seriesReleases(123, { seasonNumber: 2 });
  assert.deepEqual(releases.map(item => item.title), ['Show S02 pack']);
  assert.equal(releases[0].source, 'EZTV');
});

test('monitors only the selected episode then adds its verified magnet to qBittorrent', async () => {
  const resolved = [];
  const media = new MediaClients({ tvProvider: { resolveToken: (token, scope) => { resolved.push({ token, scope }); return { magnetUrl: 'magnet:?xt=urn:btih:' + 'A'.repeat(40), infoHash: 'a'.repeat(40), title: 'Show S01E02' }; } } });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123 });
  const sent = [];
  media.arr = async (_service, requestPath, options) => {
    if (requestPath === '/episode/91' && !options) return { id: 91, seriesId: 7, seasonNumber: 1, episodeNumber: 2, monitored: false };
    sent.push({ requestPath, method: options.method, body: JSON.parse(options.body) });
    return {};
  };
  const qbit = [];
  media.qbit = async (requestPath, options) => {
    if (requestPath === '/torrents/info') return [];
    qbit.push({ requestPath, body: Object.fromEntries(options.body) });
    return null;
  };
  const result = await media.downloadSeriesRelease(123, { downloadToken: 'token', episodeId: 91 });
  assert.deepEqual(resolved, [{ token: 'token', scope: { tvdbId: 123, seasonNumber: 1, episodeNumber: 2 } }]);
  assert.deepEqual(sent, [
    { requestPath: '/episode/91', method: 'PUT', body: { id: 91, seriesId: 7, seasonNumber: 1, episodeNumber: 2, monitored: true } },
  ]);
  assert.deepEqual(qbit, [{ requestPath: '/torrents/add', body: { urls: 'magnet:?xt=urn:btih:' + 'A'.repeat(40), category: 'series' } }]);
  assert.deepEqual(result, { accepted: true, duplicate: false, hash: 'a'.repeat(40) });
});

test('returns idempotent success without monitoring or adding a duplicate TV torrent', async () => {
  const media = new MediaClients({ tvProvider: { resolveToken: () => ({ magnetUrl: 'magnet:?xt=urn:btih:' + 'B'.repeat(40), infoHash: 'b'.repeat(40), title: 'Show S02' }) } });
  media.ensureSeries = async () => ({ id: 7, seasons: [{ seasonNumber: 1, monitored: false }, { seasonNumber: 2, monitored: false }] });
  const sent = [];
  media.arr = async (...args) => { sent.push(args); return {}; };
  media.qbit = async requestPath => requestPath === '/torrents/info' ? [{ hash: 'B'.repeat(40) }] : assert.fail('must not add duplicate');
  assert.deepEqual(await media.downloadSeriesRelease(123, { downloadToken: 'token', seasonNumber: 2 }), { accepted: true, duplicate: true, hash: 'b'.repeat(40) });
  assert.equal(sent.length, 0);
});

test('grabs a verified Prowlarr fallback through Sonarr after monitoring the episode', async () => {
  const media = new MediaClients({ tvProvider: { resolveToken: () => ({ sourceMode: 'prowlarr', guid: 'g', indexerId: 4, infoHash: null, title: 'Show S01E02' }) } });
  media.ensureSeries = async () => ({ id: 7 });
  const sent = [];
  media.arr = async (_service, requestPath, options) => {
    if (requestPath === '/episode/91' && !options) return { id: 91, seriesId: 7, seasonNumber: 1, episodeNumber: 2, monitored: false };
    sent.push({ requestPath, method: options.method, body: JSON.parse(options.body) });
    return {};
  };
  media.qbit = async () => assert.fail('Prowlarr grab must go through Sonarr');
  assert.deepEqual(await media.downloadSeriesRelease(123, { downloadToken: 'token', episodeId: 91 }), { accepted: true, duplicate: false, hash: null });
  assert.deepEqual(sent, [
    { requestPath: '/episode/91', method: 'PUT', body: { id: 91, seriesId: 7, seasonNumber: 1, episodeNumber: 2, monitored: true } },
    { requestPath: '/release', method: 'POST', body: { guid: 'g', indexerId: 4 } },
  ]);
});

test('rejects legacy Sonarr release identifiers for TV downloads', async () => {
  const media = new MediaClients({ tvProvider: { resolveToken: () => assert.fail('must not resolve') } });
  await assert.rejects(media.downloadSeriesRelease(123, { guid: 'g', indexerId: 4, episodeId: 91 }), /invalid_download_token/);
});

test('normalizes the managed Radarr library and matches Jellyfin by path', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'media-library-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const movieDir = path.join(root, 'The Batman (2022)');
  const video = path.join(movieDir, 'The Batman.mp4');
  await fs.mkdir(movieDir, { recursive: true });
  await fs.writeFile(video, 'video');
  await fs.writeFile(path.join(movieDir, 'The Batman.vi.srt'), 'subtitle');
  const media = new MediaClients({ libraryRoot: root, jellyfinApiKey: 'token' });
  media.arr = async (_service, requestPath) => requestPath === '/movie' ? [{ id: 11, title: 'The Batman', year: 2022, path: movieDir, movieFile: { path: video, mediaInfo: { videoCodec: 'h264', audioCodec: 'aac' } } }] : [];
  media.jellyfin = async () => ({ Items: [{ Id: 'jf-1', Path: video, UserData: { Played: true } }] });

  const result = await media.library();
  assert.equal(result.length, 1);
  assert.equal(result[0].jellyfinId, 'jf-1');
  assert.equal(result[0].subtitleCount, 1);
});

test('uploads and deletes only generated subtitle sidecars', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'media-subtitle-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const movieDir = path.join(root, 'Movie');
  const video = path.join(movieDir, 'Movie.mp4');
  await fs.mkdir(movieDir, { recursive: true });
  await fs.writeFile(video, 'video');
  const media = new MediaClients({ libraryRoot: root });
  media.arr = async () => ({ id: 7, path: movieDir, movieFile: { path: video } });
  media.refreshSubtitles = async () => null;
  media.refreshJellyfin = async () => null;

  const uploaded = await media.uploadLocalSubtitle(7, { fileName: 'source.srt', contentBase64: Buffer.from('subtitle').toString('base64'), language: 'vi', forced: false, hearingImpaired: true });
  assert.equal(uploaded.name, 'Movie.vi.hi.srt');
  assert.equal(await fs.readFile(path.join(movieDir, uploaded.name), 'utf8'), 'subtitle');
  await media.deleteLocalSubtitle(7, uploaded.id);
  await assert.rejects(fs.stat(path.join(movieDir, uploaded.name)), /ENOENT/);
});

test('deletes Arr media before deleting its related torrent data', async () => {
  const calls = [];
  const media = new MediaClients({ libraryRoot: '/data/library/movies' });
  media.arr = async (_service, requestPath, options = {}) => {
    calls.push(`${options.method ?? 'GET'} ${requestPath}`);
    if (requestPath === '/movie/7') return { id: 7, path: '/data/library/movies/Movie', movieFile: { path: '/data/library/movies/Movie/Movie.mp4' } };
    if (requestPath.startsWith('/history?movieId=')) return { records: [{ eventType: 'grabbed', data: { torrentInfoHash: 'ABC' } }] };
    return null;
  };
  media.torrentAction = async (action, hash) => calls.push(`QBIT ${action} ${hash}`);
  media.refreshJellyfin = async () => calls.push('JELLYFIN');

  assert.deepEqual(await media.deleteManagedMovie(7), { status: 'deleted', torrentHashes: ['abc'] });
  assert.deepEqual(calls, ['GET /movie/7', 'GET /history?movieId=7&pageSize=100', 'DELETE /movie/7?deleteFiles=true&addImportExclusion=false', 'QBIT delete abc', 'JELLYFIN']);
});

test('does not delete torrent data when deleting the Arr movie fails', async () => {
  let qbitCalled = false;
  const media = new MediaClients({ libraryRoot: '/data/library/movies' });
  media.arr = async (_service, requestPath, options = {}) => {
    if (requestPath === '/movie/7') return { id: 7, path: '/data/library/movies/Movie', movieFile: { path: '/data/library/movies/Movie/Movie.mp4' } };
    if (requestPath.startsWith('/history?movieId=')) return { records: [] };
    if (options.method === 'DELETE') throw new Error('Radarr failed');
  };
  media.torrentAction = async () => { qbitCalled = true; };
  await assert.rejects(media.deleteManagedMovie(7), /Radarr failed/);
  assert.equal(qbitCalled, false);
});
