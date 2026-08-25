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
  jsonRequest,
  loginSucceeded,
  MediaClients,
  normalizeRelease,
  normalizeTorrent,
  normalizeSubtitleEpisode,
  normalizeSubtitleMedia,
  qbitActionEndpoint,
  ReleaseSearchCache,
} from '../src/media-clients.mjs';

test('aborts a stalled JSON request at its timeout', async t => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  let aborted = false;
  globalThis.fetch = (_url, { signal }) => new Promise((_, reject) => {
    signal.addEventListener('abort', () => {
      aborted = true;
      reject(signal.reason);
    }, { once: true });
  });

  await assert.rejects(jsonRequest('https://media.test/stalled', { timeoutMs: 5 }), error => {
    assert.equal(error.code, 'upstream_timeout');
    return true;
  });
  assert.equal(aborted, true);
});

test('clears the JSON request timeout after a successful response', async t => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  let signal;
  globalThis.fetch = async (_url, options) => {
    signal = options.signal;
    return new Response('{"ok":true}', { headers: { 'content-type': 'application/json' } });
  };

  assert.deepEqual(await jsonRequest('https://media.test/ready', { timeoutMs: 5 }), { ok: true });
  await new Promise(resolve => setTimeout(resolve, 15));
  assert.equal(signal.aborted, false);
});

test('forwards an external abort reason to the JSON request signal', async t => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  const controller = new AbortController();
  const reason = new Error('caller cancelled');
  let requestSignal;
  globalThis.fetch = async (_url, { signal }) => {
    requestSignal = signal;
    return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
  };

  const pending = jsonRequest('https://media.test/cancelled', { signal: controller.signal, timeoutMs: 1000 });
  controller.abort(reason);
  await assert.rejects(pending, error => error === reason);
  assert.equal(requestSignal.reason, reason);
});

test('bounds raw qBittorrent and Jellyfin fetches without a caller signal', async t => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  globalThis.fetch = (_url, { signal }) => new Promise((_, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });
  const config = {
    qbitUrl: 'https://qbit.test', qbitUser: 'user', qbitPassword: 'pass',
    jellyfinUrl: 'https://jellyfin.test', jellyfinApiKey: 'key', sourceTimeoutMs: 5,
  };

  const qbitClient = new MediaClients(config);
  qbitClient.qbitCookie = 'SID=1';
  const deadline = promise => Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => {
      const error = new Error('test_deadline');
      error.code = 'test_deadline';
      reject(error);
    }, 50)),
  ]);

  for (const request of [
    () => new MediaClients(config).qbitLogin(),
    () => qbitClient.qbit('/app/version'),
    () => new MediaClients(config).refreshJellyfin(),
  ]) {
    await assert.rejects(deadline(request()), error => {
      assert.equal(error.code, 'upstream_timeout');
      return true;
    });
  }
});

test('aborts a raw fetch at its deadline even with a live caller signal', async t => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  let requestSignal;
  globalThis.fetch = (_url, { signal }) => {
    requestSignal = signal;
    return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
  };
  const controller = new AbortController();
  const media = new MediaClients({ qbitUrl: 'https://qbit.test', qbitUser: 'user', qbitPassword: 'pass', sourceTimeoutMs: 5 });

  await assert.rejects(media.qbitLogin({ signal: controller.signal }), error => {
    assert.equal(error.code, 'upstream_timeout');
    return true;
  });
  assert.equal(controller.signal.aborted, false);
  assert.equal(requestSignal.aborted, true);
  assert.equal(requestSignal.reason.code, 'upstream_timeout');
});

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

test('fails a release search with a stable timeout error', async () => {
  const cache = new ReleaseSearchCache({ ttlMs: 600000, timeoutMs: 5 });
  await assert.rejects(cache.get('414906', () => new Promise(() => {})), /upstream_timeout/);
});

test('allows normal indexer latency while searches still run in parallel', () => {
  const media = new MediaClients({});
  assert.equal(media.sourceTimeoutMs, 8000);
  assert.equal(media.tvSourceTimeoutMs, 30000);
  assert.equal(media.releaseCache.timeoutMs, 31000);
});

test('keeps a successful empty release result in the full-result cache', async () => {
  let calls = 0;
  const cache = new ReleaseSearchCache({ ttlMs: 600000 });
  const search = async () => { calls += 1; return []; };

  assert.deepEqual(await cache.get('movie', search), []);
  assert.deepEqual(await cache.get('movie', search), []);
  assert.equal(calls, 1);
});

test('uses a short ttl for partial releases and prunes expired and oldest cache entries', async () => {
  let now = 1000;
  let calls = 0;
  const cache = new ReleaseSearchCache({
    ttlMs: 600000,
    partialTtlMs: 30000,
    maxEntries: 2,
    now: () => now,
  });
  const defaults = new ReleaseSearchCache();
  assert.equal(defaults.ttlMs, 600000);
  assert.equal(defaults.partialTtlMs, 30000);
  assert.equal(defaults.maxEntries, 200);
  const partial = async () => ({ items: [{ guid: `partial-${++calls}` }], partial: true, sources: {} });

  assert.equal((await cache.get('partial', partial)).items[0].guid, 'partial-1');
  now += 29999;
  assert.equal((await cache.get('partial', partial)).items[0].guid, 'partial-1');
  now += 2;
  assert.equal((await cache.get('partial', partial)).items[0].guid, 'partial-2');

  await cache.get('full-a', async () => ({ items: [], partial: false, sources: {} }));
  await cache.get('full-b', async () => ({ items: [], partial: false, sources: {} }));
  assert.equal(cache.values.size, 2);
  assert.equal(cache.values.has('partial'), false);

  now += 600001;
  await cache.get('full-c', async () => ({ items: [], partial: false, sources: {} }));
  assert.deepEqual([...cache.values.keys()], ['full-c']);
});

test('a forced release search bypasses a populated cache entry', async () => {
  let calls = 0;
  const cache = new ReleaseSearchCache({ ttlMs: 600000 });
  const search = async () => [{ guid: `result-${++calls}` }];

  assert.deepEqual(await cache.get('movie', search), [{ guid: 'result-1' }]);
  assert.deepEqual(await cache.get('movie', search, { force: true }), [{ guid: 'result-2' }]);
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
    source: 'Prowlarr', sourceGroup: 'default',
    seeders: 22, peers: 4, quality: 'WEBDL-1080p', resolution: 1080,
    codec: 'H.265', rejected: true, downloadable: true, rejections: ['Not preferred'],
  });
});

test('keeps cutoff-rejected releases manually downloadable but blocks imported duplicates', () => {
  const cutoff = normalizeRelease({
    guid: 'cutoff', indexerId: 2, title: 'Movie 1080p',
    rejected: true, rejections: ['Existing file meets cutoff: Bluray-1080p'],
  });
  const duplicate = normalizeRelease({
    guid: 'duplicate', indexerId: 2, title: 'Movie 2160p',
    rejected: true, rejections: ['Has same torrent hash as a grabbed and imported release'],
  });

  assert.equal(cutoff.downloadable, true);
  assert.equal(duplicate.downloadable, false);
});

test('marks releases from public-domain indexers without changing ordinary releases', () => {
  const publicRelease = normalizeRelease({
    guid: 'archive-guid', indexerId: 12, indexer: 'Internet Archive', title: 'Public Film 1080p', size: 100,
  });
  const ordinaryRelease = normalizeRelease({
    guid: 'yts-guid', indexerId: 2, indexer: 'YTS', title: 'Film 1080p', size: 100,
  });

  assert.equal(publicRelease.source, 'Internet Archive');
  assert.equal(publicRelease.sourceGroup, 'free_public_domain');
  assert.equal(ordinaryRelease.sourceGroup, 'default');
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
  const media = new MediaClients({});
  media.qbit = async () => [
    { hash: 'active', name: 'Active', progress: .5, state: 'downloading', category: 'movies' },
    { hash: 'waiting', name: 'Waiting', progress: 1, state: 'stalledUP', category: 'movies' },
    { hash: 'done', name: 'Done', progress: 1, state: 'forcedUP', category: 'movies' },
  ];
  media.arr = async (service, requestPath) => {
    assert.equal(service, 'radarr');
    assert.equal(requestPath, '/history?page=1&pageSize=1000&sortKey=date&sortDirection=descending');
    return { records: [{ eventType: 'downloadFolderImported', downloadId: 'DONE' }] };
  };

  assert.deepEqual((await media.downloads()).map(item => [item.hash, item.importStatus, item.state]), [
    ['active', 'downloading', 'downloading'],
    ['waiting', 'checking_import', 'importing'],
    ['done', 'checking_import', 'importing'],
  ]);
  await Promise.all(media.importedIdsRefreshes.values());
  assert.deepEqual((await media.downloads()).map(item => [item.hash, item.importStatus, item.state]), [
    ['active', 'downloading', 'downloading'],
    ['waiting', 'awaiting_import', 'importing'],
  ]);
});

test('returns download snapshots without waiting for a coalesced history refresh', async () => {
  const media = new MediaClients({});
  media.qbit = async () => [
    { hash: 'done', name: 'Done', progress: 1, state: 'forcedUP', category: 'movies' },
  ];
  let historyCalls = 0;
  let resolveHistory;
  const history = new Promise(resolve => { resolveHistory = resolve; });
  media.arr = async () => { historyCalls += 1; return history; };

  const first = media.downloads();
  await new Promise(resolve => setImmediate(resolve));
  const second = media.downloads();
  const outcome = await Promise.race([
    Promise.all([first, second]),
    new Promise(resolve => setTimeout(() => resolve('slow'), 30)),
  ]);
  resolveHistory({ records: [{ eventType: 'downloadFolderImported', downloadId: 'DONE' }] });
  await Promise.all([first, second]);

  assert.notEqual(outcome, 'slow');
  assert.equal(historyCalls, 1);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(await media.downloads(), []);
});

test('batches 50 and 200 completed torrents into at most one Arr history page per category', async () => {
  for (const [count, mixed] of [[50, false], [200, true]]) {
    const calls = [];
    const media = new MediaClients({});
    media.qbit = async () => Array.from({ length: count }, (_, index) => ({
      hash: `hash-${index}`,
      name: `Torrent ${index}`,
      progress: 1,
      state: 'stalledUP',
      category: mixed && index % 2 ? 'series' : 'movies',
    }));
    media.arr = async (service, requestPath) => {
      calls.push([service, requestPath]);
      return service === 'radarr'
        ? { records: [{ eventType: 'downloadFolderImported', downloadId: 'HASH-0' }] }
        : { records: [{ eventType: 'downloadFolderImported', data: { downloadId: 'HASH-1' } }] };
    };

    assert.equal((await media.downloads()).length, count);
    await Promise.all(media.importedIdsRefreshes.values());
    const downloads = await media.downloads();
    assert.equal(downloads.length, count - (mixed ? 2 : 1));
    assert.equal(downloads.some(item => item.hash === 'hash-0'), false);
    assert.equal(downloads.some(item => item.hash === 'hash-1'), !mixed);
    assert.deepEqual(calls, (mixed ? ['radarr', 'sonarr'] : ['radarr']).map(service => [
      service,
      '/history?page=1&pageSize=1000&sortKey=date&sortDirection=descending',
    ]));
  }
});

test('matches Arr import history by download hash without relying on its broken filter', async () => {
  const media = new MediaClients({});
  let requestPath;
  media.arr = async (_service, path) => {
    requestPath = path;
    return { records: [{ eventType: 'downloadFolderImported', data: { downloadId: 'ABC123' } }] };
  };
  assert.equal(await media.isImported('abc123', 'movies'), true);
  assert.equal(requestPath, '/history?page=1&pageSize=1000&sortKey=date&sortDirection=descending');
  assert.doesNotMatch(requestPath, /downloadId=/);
});

test('propagates a download poll abort signal through qBittorrent auth/info and Arr history', async t => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  const controller = new AbortController();
  const fetchSignals = [];
  let arrSignal;
  globalThis.fetch = async (url, options) => {
    fetchSignals.push(options.signal);
    if (String(url).endsWith('/auth/login')) {
      return new Response('Ok.', { headers: { 'set-cookie': 'SID=test; Path=/' } });
    }
    return new Response(JSON.stringify([
      { hash: 'waiting', name: 'Waiting', progress: 1, state: 'stalledUP', category: 'series' },
    ]));
  };
  const media = new MediaClients({ qbitUrl: 'http://qbit.test', qbitUser: 'user', qbitPassword: 'pass' });
  media.arr = async (service, requestPath, options) => {
    assert.equal(service, 'sonarr');
    assert.equal(requestPath, '/history?page=1&pageSize=1000&sortKey=date&sortDirection=descending');
    arrSignal = options.signal;
    return { records: [] };
  };

  await media.downloads({ signal: controller.signal });
  assert.equal(fetchSignals.length, 2);
  assert.notEqual(fetchSignals[0], controller.signal);
  assert.notEqual(fetchSignals[1], controller.signal);
  assert.equal(arrSignal, controller.signal);
});

test('does not turn an aborted Arr history request into an awaiting import result', async () => {
  const controller = new AbortController();
  const reason = new Error('subscriber disconnected');
  const media = new MediaClients({});
  media.qbit = async () => [
    { hash: 'waiting', name: 'Waiting', progress: 1, state: 'stalledUP', category: 'movies' },
  ];
  media.arr = async (_service, _requestPath, { signal }) => new Promise((_, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });

  const downloads = await media.downloads({ signal: controller.signal });
  await new Promise(resolve => setImmediate(resolve));
  controller.abort(reason);
  await Promise.all(media.importedIdsRefreshes.values());
  assert.equal(downloads[0].importStatus, 'checking_import');
  assert.equal(media.importedIdsCache.has('movies'), false);
});

test('searches and normalizes Sonarr series by TVDB id', async () => {
  const media = new MediaClients({});
  media.arr = async (_service, requestPath) => {
    assert.equal(requestPath, '/series/lookup?term=batman');
    return [{ tvdbId: 123, title: 'Batman', year: 2024, overview: 'Series', remotePoster: 'poster.jpg', seasons: [{ seasonNumber: 1 }] }];
  };
  assert.deepEqual(await media.searchSeries('batman'), [{ mediaType: 'series', tvdbId: 123, title: 'Batman', originalTitle: undefined, aliases: [], studios: [], networks: [], people: [], year: 2024, overview: 'Series', poster: 'poster.jpg', inLibrary: false, seasons: [{ seasonNumber: 1 }] }]);
});

test('waits briefly for Sonarr to populate episodes after adding a series', async () => {
  const media = new MediaClients({ episodeRetryDelayMs: 0 });
  media.ensureSeries = async () => ({ id: 77 });
  let calls = 0;
  media.arr = async (_service, requestPath) => {
    assert.equal(requestPath, '/episode?seriesId=77');
    calls += 1;
    return calls === 1 ? [] : [{ id: 91, seasonNumber: 1, episodeNumber: 1, title: 'Pilot', hasFile: false }];
  };
  const episodes = await media.seriesEpisodes(123);
  assert.equal(calls, 2);
  assert.deepEqual(episodes, [{ episodeId: 91, seasonNumber: 1, episodeNumber: 1, title: 'Pilot', airDate: undefined, hasFile: false }]);
});

test('passes season and episode scopes to YTS when the Sonarr source fails', async () => {
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

test('merges YTS, EZTV, and Free & Public Domain TV releases when each source is available', async () => {
  const media = new MediaClients({ tvProvider: { search: async () => [] } });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Archive Show', year: 2024 });
  media.arr = async (_service, requestPath) => {
    assert.equal(requestPath, '/release?seriesId=7&seasonNumber=1');
    return [
      { title: 'Archive Show S01 1080p', guid: 'g1', indexerId: 4, indexer: 'EZTV', fullSeason: true, seasonNumber: 1 },
      { title: 'Archive Show S01 720p', guid: 'g2', indexerId: 12, indexer: 'Internet Archive', fullSeason: true, seasonNumber: 1 },
    ];
  };
  media.tvProvider.search = async () => [{ title: 'Archive Show S01 2160p', source: 'YTS Official', sourceMode: 'yts' }];
  media.tvProvider.normalizeSonarr = row => ({ title: row.title, source: row.indexer, sourceMode: 'prowlarr' });

  const releases = await media.seriesReleases(123, { seasonNumber: 1 });
  assert.deepEqual(releases.map(item => item.source), ['YTS Official', 'EZTV', 'Internet Archive']);
});

test('keeps successful TV sources when Free & Public Domain fails', async () => {
  const media = new MediaClients({ tvProvider: { search: async () => [] } });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024 });
  media.arr = async (_service, requestPath) => {
    assert.equal(requestPath, '/release?seriesId=7&seasonNumber=1');
    return [{ title: 'Show S01', guid: 'g1', indexerId: 4, indexer: 'EZTV', fullSeason: true, seasonNumber: 1 }];
  };
  media.tvProvider.normalizeSonarr = row => ({ title: row.title, source: row.indexer, sourceMode: 'prowlarr' });
  const releases = await media.seriesReleases(123, { seasonNumber: 1 });
  assert.deepEqual(releases.map(item => item.source), ['EZTV']);
});

test('returns fast YTS TV releases without waiting for a stalled Sonarr source', async () => {
  const media = new MediaClients({
    sourceTimeoutMs: 5,
    tvSourceTimeoutMs: 5,
    tvProvider: {
      search: async () => [{ title: 'Show S01 1080p', source: 'YTS Official', sourceMode: 'yts', rejected: false }],
      normalizeSonarr: row => row,
    },
  });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024 });
  media.arr = async (_service, path) => {
    if (path === '/release?seriesId=7&seasonNumber=1') return new Promise(() => {});
    assert.fail(path);
  };

  const releases = await media.seriesReleases(123, { seasonNumber: 1 });
  assert.deepEqual(releases.map(item => item.source), ['YTS Official']);
});

test('prepares TV releases with per-source states and aborts a timed-out source', async () => {
  let ytsAborted = false;
  let sonarrSignal;
  const media = new MediaClients({
    tvSourceTimeoutMs: 5,
    tvProvider: {
      search: async (_scope, { signal }) => new Promise((_, reject) => signal.addEventListener('abort', () => {
        ytsAborted = true;
        reject(signal.reason);
      }, { once: true })),
      normalizeSonarr: row => ({ title: row.title, source: row.indexer, sourceMode: 'prowlarr' }),
    },
  });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024 });
  media.arr = async (_service, requestPath, options) => {
    assert.equal(requestPath, '/release?seriesId=7&seasonNumber=1');
    sonarrSignal = options.signal;
    return [{ title: 'Show S01', guid: 'g1', indexerId: 4, indexer: 'EZTV' }];
  };

  const prepared = await media.prepareSeriesReleases(123, { seasonNumber: 1 });
  assert.equal(ytsAborted, true);
  assert.equal(sonarrSignal instanceof AbortSignal, true);
  assert.deepEqual(prepared.sources, {
    yts: { state: 'timeout', itemCount: 0 },
    sonarr: { state: 'ready', itemCount: 1 },
  });
  assert.equal(prepared.partial, true);
  assert.equal(prepared.prepared, true);
  assert.deepEqual(prepared.items.map(item => item.source), ['EZTV']);
});

test('keeps Sonarr prepare and download available when direct YTS TV is disabled', async () => {
  let directCalls = 0;
  const sent = [];
  const media = new MediaClients({
    tvDirectEnabled: false,
    tvProvider: {
      search: async () => { directCalls += 1; return []; },
      normalizeSonarr: row => ({ ...row, source: row.indexer, sourceMode: 'prowlarr', downloadToken: 'token' }),
      resolveToken: () => ({ sourceMode: 'prowlarr', guid: 'g', indexerId: 4, infoHash: null }),
    },
  });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024, seasons: [{ seasonNumber: 1, monitored: false }] });
  media.arr = async (_service, requestPath, options = {}) => {
    if (requestPath === '/release?seriesId=7&seasonNumber=1') {
      return [{ title: 'Show S01', guid: 'g', indexerId: 4, indexer: 'EZTV' }];
    }
    sent.push({ requestPath, method: options.method });
    return {};
  };
  media.qbit = async () => assert.fail('Prowlarr release must not use qBittorrent directly');

  const prepared = await media.prepareSeriesReleases(123, { seasonNumber: 1 });
  assert.equal(directCalls, 0);
  assert.deepEqual(prepared.items.map(item => item.source), ['EZTV']);
  assert.deepEqual(prepared.sources, { sonarr: { state: 'ready', itemCount: 1 } });

  await media.downloadSeriesRelease(123, { downloadToken: 'token', seasonNumber: 1 });
  assert.deepEqual(sent, [
    { requestPath: '/series/7', method: 'PUT' },
    { requestPath: '/release', method: 'POST' },
  ]);
});

test('filters prepared and legacy TV releases by normalized source group', async () => {
  const media = new MediaClients({
    tvProvider: {
      search: async () => [{ title: 'Show S01 YTS', source: 'YTS Official', sourceMode: 'yts' }],
      normalizeSonarr: row => ({ title: row.title, source: row.indexer, sourceMode: 'prowlarr' }),
    },
  });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024 });
  media.arr = async () => [
    { title: 'Show S01 EZTV', guid: 'g1', indexerId: 4, indexer: 'EZTV' },
    { title: 'Show S01 Archive', guid: 'g2', indexerId: 12, indexer: 'Internet Archive' },
  ];

  const prepared = await media.prepareSeriesReleases(123, { seasonNumber: 1, freePublicDomain: true });
  assert.deepEqual(prepared.items.map(item => item.source), ['Internet Archive']);
  assert.deepEqual(prepared.sources, {
    yts: { state: 'ready', itemCount: 0 },
    sonarr: { state: 'ready', itemCount: 1 },
  });
  assert.deepEqual((await media.seriesReleases(123, { seasonNumber: 1 })).map(item => item.source), [
    'YTS Official', 'EZTV', 'Internet Archive',
  ]);
});

test('treats successful empty TV sources as a cacheable full result', async () => {
  let ensureCalls = 0;
  let ytsCalls = 0;
  let sonarrCalls = 0;
  const media = new MediaClients({
    tvProvider: {
      search: async () => { ytsCalls += 1; return []; },
      normalizeSonarr: row => row,
    },
  });
  media.ensureSeries = async () => { ensureCalls += 1; return { id: 7, tvdbId: 123, title: 'Show', year: 2024 }; };
  media.arr = async () => { sonarrCalls += 1; return []; };

  const first = await media.prepareSeriesReleases(123, { seasonNumber: 1 });
  const cached = await media.prepareSeriesReleases(123, { seasonNumber: 1 });
  assert.deepEqual(first, {
    items: [],
    partial: false,
    sources: {
      yts: { state: 'ready', itemCount: 0 },
      sonarr: { state: 'ready', itemCount: 0 },
    },
    prepared: true,
  });
  assert.deepEqual(cached, first);
  assert.equal(ensureCalls, 1);
  assert.equal(ytsCalls, 1);
  assert.equal(sonarrCalls, 1);
});

test('keeps waiting for TV indexers after the direct YTS source fails', async () => {
  const media = new MediaClients({
    tvSourceTimeoutMs: 30,
    tvProvider: {
      search: async () => { throw new Error('yts_tv_provider_unavailable'); },
      normalizeSonarr: row => ({ ...row, source: row.indexer }),
    },
  });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Show', year: 2024 });
  media.arr = async () => {
    await new Promise(resolve => setTimeout(resolve, 15));
    return [{ title: 'Show S01', guid: 'g', indexerId: 4, indexer: 'Nyaa.si', fullSeason: true, seasonNumber: 1 }];
  };

  const releases = await media.seriesReleases(123, { seasonNumber: 1 });
  assert.deepEqual(releases.map(item => item.source), ['Nyaa.si']);
});

test('asks Sonarr once while Prowlarr searches all TV indexers concurrently', async () => {
  const media = new MediaClients({
    tvSourceTimeoutMs: 30,
    tvProvider: { search: async () => [], normalizeSonarr: row => ({ ...row, source: row.indexer }) },
  });
  media.ensureSeries = async () => ({ id: 7, tvdbId: 123, title: 'Anime Show', year: 2024 });
  const requests = [];
  media.arr = async (_service, requestPath) => {
    requests.push(requestPath);
    return [{ title: 'Anime Show S01', guid: 'land', indexerId: 21, indexer: 'Nyaa.land', fullSeason: true, seasonNumber: 1 }];
  };

  const releases = await media.seriesReleases(123, { seasonNumber: 1 });
  assert.deepEqual(releases.map(item => item.source), ['Nyaa.land']);
  assert.deepEqual(requests, ['/release?seriesId=7&seasonNumber=1']);
});

test('asks Radarr once while Prowlarr searches all movie indexers concurrently', async () => {
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  const requests = [];
  media.arr = async (_service, requestPath) => {
    requests.push(requestPath);
    return [
      { title: 'Movie 1080p', guid: 'yts', indexerId: 2, indexer: 'YTS' },
      { title: 'Movie 720p', guid: 'archive', indexerId: 12, indexer: 'Internet Archive' },
    ];
  };
  const releases = await media.releases(603);
  assert.deepEqual(releases.map(item => item.source), ['YTS', 'Internet Archive']);
  assert.deepEqual(requests, ['/release?movieId=7']);
});

test('prepares movie releases and keeps the legacy array while filtering public-domain items', async () => {
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  media.arr = async () => [
    { title: 'Movie YTS', guid: 'yts', indexerId: 2, indexer: 'YTS' },
    { title: 'Movie Archive', guid: 'archive', indexerId: 12, indexer: 'Internet Archive' },
  ];

  const prepared = await media.prepareMovieReleases(603, { freePublicDomain: true });
  assert.equal(prepared.prepared, true);
  assert.equal(prepared.partial, false);
  assert.deepEqual(prepared.items.map(item => item.source), ['Internet Archive']);
  assert.deepEqual(prepared.sources, { radarr: { state: 'ready', itemCount: 1 } });
  assert.deepEqual((await media.releases(603)).map(item => item.source), ['YTS', 'Internet Archive']);
});

test('keeps source-group variants distinct before public-domain filtering', async () => {
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  media.arr = async () => [
    { title: 'Same Movie', size: 1000, guid: 'archive', indexerId: 12, indexer: 'Internet Archive' },
    { title: 'Same Movie', size: 1000, guid: 'yts', indexerId: 2, indexer: 'YTS' },
  ];

  const prepared = await media.prepareMovieReleases(603, { freePublicDomain: true });
  assert.deepEqual(prepared.items.map(item => item.source), ['Internet Archive']);
});

test('preserves upstream timeout codes returned by a release source', async () => {
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  media.arr = async () => {
    const error = new Error('upstream_timeout');
    error.code = 'upstream_timeout';
    throw error;
  };

  await assert.rejects(media.prepareMovieReleases(603), error => error.code === 'upstream_timeout');
});

test('deduplicates the same movie release returned by multiple source searches', async () => {
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  media.arr = async () => [{ title: 'Movie 1080p', guid: 'same', indexerId: 2, indexer: 'YTS (Prowlarr)' }];

  const releases = await media.releases(603);
  assert.equal(releases.length, 1);
});

test('deduplicates Nyaa mirrors returned by one Radarr interactive search', async () => {
  const hash = 'a'.repeat(40);
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  const started = [];
  media.arr = async (_service, requestPath) => {
    started.push(requestPath);
    return [
      { title: 'Anime Movie 1080p', guid: `magnet:?xt=urn:btih:${hash}`, indexerId: 20, indexer: 'Nyaa.si', size: 100 },
      { title: 'Anime Movie 1080p', guid: `https://nyaa.land/download/${hash}.torrent`, indexerId: 21, indexer: 'Nyaa.land', size: 100 },
    ];
  };

  const releases = await media.releases(603);
  assert.deepEqual(started, ['/release?movieId=7']);
  assert.equal(releases.length, 1);
});

test('reports provider failure instead of pretending there are no movie releases', async () => {
  const media = new MediaClients({ sourceTimeoutMs: 20 });
  media.ensureMovie = async () => ({ id: 7 });
  media.arr = async () => { throw new Error('indexer offline'); };

  await assert.rejects(media.releases(603), /provider_unavailable/);
});

test('reports upstream timeout when every movie source reaches its deadline', async () => {
  const media = new MediaClients({ sourceTimeoutMs: 5 });
  media.ensureMovie = async () => ({ id: 7 });
  media.arr = async (_service, _path, { signal }) => new Promise((_, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });

  await assert.rejects(media.prepareMovieReleases(603), error => {
    assert.equal(error.code, 'upstream_timeout');
    assert.equal(error.message, 'upstream_timeout');
    return true;
  });
});

test('returns idempotent success when a selected movie torrent already exists', async () => {
  const hash = 'A'.repeat(40);
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  media.qbit = async requestPath => requestPath === '/torrents/info'
    ? [{ hash: hash.toLowerCase() }]
    : assert.fail('must not mutate qBittorrent');
  media.arr = async () => assert.fail('must not ask Radarr to add a duplicate');

  assert.deepEqual(await media.downloadRelease(603, {
    guid: `https://yts.gg/torrent/download/${hash}`,
    indexerId: 2,
  }), { accepted: true, duplicate: true, hash: hash.toLowerCase() });
});

test('recovers when qBittorrent reports a duplicate during the Radarr add race', async () => {
  const hash = 'B'.repeat(40).toLowerCase();
  const media = new MediaClients({});
  media.ensureMovie = async () => ({ id: 7 });
  let checks = 0;
  media.qbit = async () => ++checks === 1 ? [] : [{ hash }];
  media.arr = async () => { throw new Error('500 qBittorrent 409 Conflict'); };

  assert.deepEqual(await media.downloadRelease(603, {
    guid: `https://yts.gg/torrent/download/${hash}`,
    indexerId: 2,
  }), { accepted: true, duplicate: true, hash });
});

test('reports Free & Public Domain source health without exposing Prowlarr configuration', async () => {
  const media = new MediaClients({ tvProvider: {} });
  media.prowlarr = async () => [
    { id: 2, name: 'YTS', enable: true },
    { id: 3, name: 'EZTV', enable: true },
    { id: 12, name: 'Internet Archive', enable: true },
    { id: 5, name: 'Tokyo Toshokan', enable: true },
    { id: 20, name: 'Nyaa.si', enable: true },
    { id: 21, name: 'Nyaa.land', enable: true },
  ];
  const sources = await media.downloadSources();
  assert.deepEqual(sources, [
    { id: 'yts-official', name: 'YTS Official', state: 'ready', scopes: ['movie', 'series'] },
    { id: 'eztv', name: 'EZTV', state: 'ready', scopes: ['series'] },
    { id: 'internet-archive', name: 'Internet Archive', state: 'ready', scopes: ['movie', 'series'] },
    { id: 'tokyo-toshokan', name: 'Tokyo Toshokan', state: 'ready', scopes: ['series'] },
    { id: 'nyaa-si', name: 'Nyaa.si', state: 'ready', scopes: ['movie', 'series'], endpoint: 'https://nyaa.si/' },
    { id: 'nyaa-land', name: 'Nyaa.land', state: 'ready', scopes: ['movie', 'series'], endpoint: 'https://nyaa.land/' },
    { id: 'public-domain-torrents', name: 'Public Domain Torrents', state: 'needs_manual_feed', scopes: ['movie'], reason: 'No compatible Prowlarr feed configured' },
  ]);
});

test('reports both Nyaa indexers independently', async () => {
  const media = new MediaClients({});
  media.prowlarr = async () => [
    { id: 20, name: 'Nyaa.si', enable: true },
    { id: 21, name: 'Nyaa.land', enable: true },
  ];
  const sources = await media.downloadSources();
  assert.equal(sources.find(source => source.id === 'nyaa-si').state, 'ready');
  assert.equal(sources.find(source => source.id === 'nyaa-land').state, 'ready');
});

test('reports a Nyaa.si Cloudflare challenge without exposing upstream HTML', async () => {
  const media = new MediaClients({});
  media.prowlarr = async requestPath => requestPath === '/indexer'
    ? [{ id: 20, name: 'Nyaa.si', enable: true }, { id: 21, name: 'Nyaa.land', enable: true }]
    : [{ indexerId: 20, mostRecentFailure: '<html>Just a moment... Cloudflare Turnstile</html>' }];

  const sources = await media.downloadSources();
  const nyaa = sources.find(source => source.id === 'nyaa-si');
  assert.equal(nyaa.state, 'cloudflare_blocked');
  assert.equal(nyaa.reason, 'Cloudflare challenge requires attention');
  assert.doesNotMatch(JSON.stringify(nyaa), /<html>|Turnstile/i);
  assert.equal(sources.find(source => source.id === 'nyaa-land').state, 'ready');
});

test('reports temporary Prowlarr source failures as degraded instead of disabled', async () => {
  const media = new MediaClients({ tvProvider: {} });
  media.prowlarr = async () => { throw new Error('temporary network failure'); };
  const sources = await media.downloadSources();
  assert.equal(sources.find(source => source.id === 'yts-official').state, 'degraded');
  assert.equal(sources.find(source => source.id === 'eztv').state, 'degraded');
  assert.equal(sources.find(source => source.id === 'internet-archive').state, 'degraded');
  assert.equal(sources.find(source => source.id === 'tokyo-toshokan').state, 'degraded');
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
  media.arr = async (service, requestPath) => {
    if (service === 'radarr' && requestPath === '/movie') return [{ id: 11, title: 'The Batman', year: 2022, path: movieDir, movieFile: { path: video, mediaInfo: { videoCodec: 'h264', audioCodec: 'aac' } } }];
    if (service === 'sonarr' && requestPath === '/series') return [{ id: 21, title: 'Frieren', year: 2023, path: '/data/library/series/Frieren', statistics: { episodeFileCount: 28 }, images: [{ coverType: 'poster', remoteUrl: 'https://poster/series.jpg' }] }];
    return [];
  };
  media.jellyfin = async () => ({ Items: [
    { Id: 'jf-1', Path: video, UserData: { Played: true } },
    { Id: 'jf-series', Path: '/data/library/series/Frieren', UserData: { Played: false } },
  ] });

  const result = await media.library();
  assert.equal(result.length, 2);
  assert.equal(result[0].jellyfinId, 'jf-1');
  assert.equal(result[0].subtitleCount, 1);
  assert.deepEqual(result[1], {
    mediaId: 21,
    jellyfinId: 'jf-series',
    title: 'Frieren',
    year: 2023,
    poster: 'https://poster/series.jpg',
    path: '/data/library/series/Frieren',
    watched: false,
    playbackPositionTicks: 0,
    episodeCount: 28,
    type: 'series',
  });
});

test('builds the Arr library when Jellyfin credentials are absent', async () => {
  const media = new MediaClients({});
  media.arr = async (service, requestPath) => {
    if (service === 'radarr' && requestPath === '/movie') {
      return [{ id: 11, title: 'Movie', year: 2024, movieFile: { path: '/library/Movie.mkv' } }];
    }
    if (service === 'sonarr' && requestPath === '/series') return [];
    assert.fail(`${service} ${requestPath}`);
  };

  const result = await media.library();
  assert.equal(result.length, 1);
  assert.equal(result[0].jellyfinId, null);
});

test('matches 1000 Jellyfin items and limits subtitle scans to eight', async () => {
  const movies = Array.from({ length: 1000 }, (_, index) => ({
    id: index,
    title: `Movie ${index}`,
    year: 2024,
    movieFile: { path: `/library/Movie ${index}/Movie ${index}.mkv` },
  }));
  const media = new MediaClients({ jellyfinApiKey: 'token' });
  media.arr = async (service, requestPath) => {
    if (service === 'radarr' && requestPath === '/movie') return movies;
    if (service === 'sonarr' && requestPath === '/series') return [];
    assert.fail(`${service} ${requestPath}`);
  };
  media.jellyfin = async () => ({ Items: movies.toReversed().map(movie => ({
    Id: `jf-${movie.id}`,
    Path: movie.movieFile.path,
  })) });
  let active = 0;
  let maxActive = 0;
  media.localSubtitlesForMovie = async movie => {
    active += 1;
    maxActive = Math.max(maxActive, active);
    await new Promise(resolve => setImmediate(resolve));
    active -= 1;
    return movie.id % 2 ? [{ id: 'vi' }] : [];
  };

  const result = await media.library();
  assert.equal(result.length, 1000);
  assert.equal(result[0].jellyfinId, 'jf-0');
  assert.equal(result[999].jellyfinId, 'jf-999');
  assert.equal(result[1].subtitleCount, 1);
  assert.equal(maxActive <= 8, true);
});

test('builds compact Vietnamese subtitle coverage by series and season', async () => {
  const media = new MediaClients({});
  media.bazarr = async requestPath => {
    if (requestPath.startsWith('/movies')) return { data: [] };
    if (requestPath === '/episodes?seriesid[]=21') return { data: [
      { sonarrEpisodeId: 91, sonarrSeriesId: 21, season: 1, episode: 1, title: 'The Journey Ends', path: '/series/Frieren S01E01.mkv', missing_subtitles: [{ code2: 'en' }], subtitles: [{ code2: 'vi' }] },
      { sonarrEpisodeId: 93, sonarrSeriesId: 21, season: 2, episode: 1, title: 'New Journey', path: '/series/Frieren S02E01.mkv', missing_subtitles: [{ code2: 'vi' }], subtitles: [{ code2: 'en' }] },
    ] };
    assert.fail(`unexpected Bazarr request ${requestPath}`);
  };
  media.arr = async (service, requestPath) => {
    assert.equal(service, 'sonarr');
    if (requestPath === '/series') return [{ id: 21, title: 'Frieren', year: 2023, statistics: { episodeFileCount: 2 }, images: [{ coverType: 'poster', remoteUrl: 'https://poster/series.jpg' }] }];
    assert.fail(requestPath);
  };

  const result = await media.subtitleMedia();
  assert.deepEqual(result, [{
    mediaId: 21,
    title: 'Frieren',
    year: 2023,
    poster: 'https://poster/series.jpg',
    type: 'series',
    episodeCount: 2,
    viAvailable: 1,
    viMissing: 1,
    coverageDegraded: false,
    seasons: [
      { seasonNumber: 1, episodeCount: 1, viAvailable: 1, viMissing: 0 },
      { seasonNumber: 2, episodeCount: 1, viAvailable: 0, viMissing: 1 },
    ],
  }]);
});

test('limits series subtitle coverage fan-out to four and keeps fallback order', async () => {
  const series = Array.from({ length: 10 }, (_, index) => ({
    id: index + 1,
    title: `Series ${index + 1}`,
    statistics: { episodeFileCount: 1 },
  }));
  const media = new MediaClients({});
  let active = 0;
  let maxActive = 0;
  media.bazarr = async requestPath => {
    if (requestPath.startsWith('/movies')) return { data: [] };
    const id = Number(requestPath.match(/seriesid\[\]=(\d+)/)?.[1]);
    active += 1;
    maxActive = Math.max(maxActive, active);
    await new Promise(resolve => setImmediate(resolve));
    active -= 1;
    if (id === 3) throw new Error('Bazarr unavailable');
    return { data: [{ path: `/series/${id}.mkv`, season: 1, subtitles: [{ code2: 'vi' }] }] };
  };
  media.arr = async (service, requestPath) => {
    assert.equal(service, 'sonarr');
    if (requestPath === '/series') return series;
    if (requestPath === '/episode?seriesId=3&includeEpisodeFile=true') {
      return [{ hasFile: true, seasonNumber: 1, episodeFile: { path: '/series/3.mkv' } }];
    }
    assert.fail(requestPath);
  };

  const result = await media.subtitleMedia();
  assert.deepEqual(result.map(item => item.mediaId), series.map(item => item.id));
  assert.equal(result[2].coverageDegraded, true);
  assert.equal(result[2].viMissing, 1);
  assert.equal(maxActive <= 4, true);
});

test('loads one season lazily and puts episodes missing Vietnamese first', async () => {
  const media = new MediaClients({});
  media.arr = async (service, requestPath) => {
    assert.equal(service, 'sonarr');
    if (requestPath === '/series/21') return { id: 21, title: 'Frieren', year: 2023, images: [{ coverType: 'poster', remoteUrl: 'https://poster/series.jpg' }] };
    if (requestPath === '/episode?seriesId=21&includeEpisodeFile=true') return [
      { id: 91, seasonNumber: 1, episodeNumber: 1, title: 'Has Vietnamese', hasFile: true, episodeFile: { path: '/series/Frieren S01E01.mkv' } },
      { id: 92, seasonNumber: 1, episodeNumber: 2, title: 'Missing Vietnamese', hasFile: true, episodeFile: { path: '/series/Frieren S01E02.mkv' } },
      { id: 93, seasonNumber: 2, episodeNumber: 1, title: 'Other season', hasFile: true, episodeFile: { path: '/series/Frieren S02E01.mkv' } },
    ];
    assert.fail(requestPath);
  };
  media.bazarr = async requestPath => {
    assert.equal(requestPath, '/episodes?seriesid[]=21');
    return { data: [
      { sonarrEpisodeId: 91, missing_subtitles: [], subtitles: [{ code2: 'vi' }] },
      { sonarrEpisodeId: 92, missing_subtitles: [{ code2: 'vi' }], subtitles: [{ code2: 'en' }] },
    ] };
  };

  const result = await media.subtitleSeason(21, 1);
  assert.deepEqual(result.map(item => [item.mediaId, item.hasVietnamese]), [[92, false], [91, true]]);
  assert.equal(result[0].title, 'Frieren S01E02 • Missing Vietnamese');
});

test('keeps all Bazarr languages available for multi-provider episode results', async () => {
  const media = new MediaClients({});
  media.bazarr = async requestPath => {
    assert.equal(requestPath, '/providers/episodes?episodeid=92');
    return { data: [
      { provider: 'opensubtitlescom', language: 'vi' },
      { provider: 'gestdown', language: 'en' },
    ] };
  };
  assert.equal((await media.searchAllEpisodeSubtitles(92)).data.length, 2);
});

test('searches one season and downloads the best Vietnamese subtitle for each missing episode', async () => {
  const media = new MediaClients({});
  const downloaded = [];
  const refreshed = [];
  media.subtitleSeason = async () => [
    { mediaId: 91, hasVietnamese: true },
    { mediaId: 92, hasVietnamese: false },
    { mediaId: 93, hasVietnamese: false },
    { mediaId: 94, hasVietnamese: false },
  ];
  media.searchEpisodeSubtitles = async episodeId => {
    if (episodeId === 92) return { data: [
      { language: 'vi', score: 70, provider: 'gestdown', downloadToken: 'low' },
      { language: 'vi', score: 95, provider: 'opensubtitlescom', downloadToken: 'best' },
    ] };
    if (episodeId === 93) return { data: [] };
    throw new Error('provider unavailable');
  };
  media.downloadEpisodeSubtitle = async (episodeId, subtitle) => downloaded.push([episodeId, subtitle.downloadToken]);
  media.refreshEpisodeSubtitles = async episodeId => refreshed.push(episodeId);
  media.refreshJellyfin = async () => refreshed.push('jellyfin');

  const result = await media.searchSeasonSubtitles(21, 1);

  assert.deepEqual(result, {
    seriesId: 21,
    seasonNumber: 1,
    total: 4,
    alreadyAvailable: 1,
    downloaded: 1,
    unavailable: 1,
    failed: 1,
  });
  assert.deepEqual(downloaded, [[92, 'best']]);
  assert.deepEqual(refreshed, [92, 'jellyfin']);
});

test('coalesces duplicate in-flight season subtitle batches', async () => {
  const media = new MediaClients({});
  let seasonCalls = 0;
  let releaseSearch;
  media.subtitleSeason = async () => {
    seasonCalls++;
    return [{ mediaId: 92, hasVietnamese: false }];
  };
  media.searchEpisodeSubtitles = () => new Promise(resolve => { releaseSearch = resolve; });
  media.downloadEpisodeSubtitle = async () => null;
  media.refreshEpisodeSubtitles = async () => null;
  media.refreshJellyfin = async () => null;

  const first = media.searchSeasonSubtitles(21, 1);
  const second = media.searchSeasonSubtitles(21, 1);
  await new Promise(resolve => setImmediate(resolve));
  releaseSearch({ data: [{ language: 'vi', score: 80, downloadToken: 'token' }] });

  assert.deepEqual(await first, await second);
  assert.equal(seasonCalls, 1);
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
