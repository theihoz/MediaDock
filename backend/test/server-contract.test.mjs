import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import test from 'node:test';
import { createDownloadEventsHub } from '../src/download-events.mjs';
import { jsonRequest, MediaClients } from '../src/media-clients.mjs';
import { createServer } from '../src/server.mjs';
import { createSubtitleToken } from '../src/subtitle-token.mjs';

function fakeMedia(overrides = {}) {
  return {
    movie: async id => ({ tmdbId: Number(id), title: 'Movie' }),
    releases: async () => [{ title: 'Movie release' }],
    prepareMovieReleases: async () => ({ items: [], partial: false, sources: {}, prepared: true }),
    series: async id => ({ tvdbId: Number(id), title: 'Series' }),
    normalizeSeries: value => value,
    seriesEpisodes: async () => [{ episodeId: 21 }],
    seriesReleases: async () => [{ title: 'Series release' }],
    prepareSeriesReleases: async () => ({ items: [], partial: false, sources: {}, prepared: true }),
    uploadLocalSubtitle: async () => ({ uploaded: true }),
    deleteManagedMovie: async () => ({ deleted: true }),
    ...overrides,
  };
}

async function start(t, media, subtitleMaintenance) {
  const server = createServer({ media, ...(subtitleMaintenance ? { subtitleMaintenance } : {}) });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

async function request(base, path, { method = 'GET', json, raw } = {}) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: json !== undefined || raw !== undefined ? { 'content-type': 'application/json' } : undefined,
    body: json !== undefined ? JSON.stringify(json) : raw,
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null, headers: response.headers };
}

test('exposes automatic Vietnamese subtitle maintenance status and trigger', async t => {
  let runs = 0;
  const scheduler = {
    status: () => ({ enabled: true, state: 'idle', result: null }),
    run: async () => { runs += 1; },
  };
  const base = await start(t, fakeMedia(), scheduler);

  assert.deepEqual((await request(base, '/v1/subtitles/maintenance/status')).body, {
    enabled: true, state: 'idle', result: null,
  });
  assert.equal((await request(base, '/v1/subtitles/maintenance/run', { method: 'POST' })).status, 202);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(runs, 1);
});

function slowChunkedRequest(base, path, chunks) {
  return new Promise((resolve, reject) => {
    let finished = false;
    let response;
    const complete = () => { if (finished && response) resolve(response); };
    const req = http.request(`${base}${path}`, { method: 'DELETE', agent: false, headers: { 'content-type': 'application/json', 'transfer-encoding': 'chunked' } }, res => {
      const parts = [];
      res.on('data', chunk => parts.push(chunk));
      res.on('end', () => {
        response = { status: res.statusCode, body: JSON.parse(Buffer.concat(parts).toString('utf8')) };
        complete();
      });
    });
    req.on('error', reject);
    req.on('finish', () => { finished = true; complete(); });
    req.write(chunks[0]);
    setTimeout(() => {
      req.write(chunks[1]);
      setTimeout(() => req.end(chunks[2]), 20);
    }, 20);
  });
}

test('keeps legacy GET shapes and detail lookups do not prepare releases', async t => {
  let moviePrepares = 0;
  let seriesPrepares = 0;
  const base = await start(t, fakeMedia({
    prepareMovieReleases: async () => { moviePrepares += 1; return { items: [], partial: false, sources: {}, prepared: true }; },
    prepareSeriesReleases: async () => { seriesPrepares += 1; return { items: [], partial: false, sources: {}, prepared: true }; },
  }));

  assert.equal((await request(base, '/v1/movies/7')).status, 200);
  assert.equal((await request(base, '/v1/series/8')).status, 200);
  assert.equal(moviePrepares, 0);
  assert.equal(seriesPrepares, 0);

  assert.ok(Array.isArray((await request(base, '/v1/movies/7/releases')).body));
  assert.ok(Array.isArray((await request(base, '/v1/series/8/episodes')).body));
  assert.ok(Array.isArray((await request(base, '/v1/series/8/releases?seasonNumber=0')).body));
});

test('POST prepare routes return envelopes and pass validated scopes', async t => {
  const calls = [];
  const movieEnvelope = { items: [{ title: 'Movie release' }], partial: false, sources: { radarr: { state: 'ready', itemCount: 1 } }, prepared: true };
  const seriesEnvelope = { items: [{ title: 'Series release' }], partial: true, sources: { sonarr: { state: 'timeout', itemCount: 0 } }, prepared: true };
  const base = await start(t, fakeMedia({
    prepareMovieReleases: async (id, options) => { calls.push(['movie', id, options]); return movieEnvelope; },
    seriesEpisodes: async id => { calls.push(['episodes', id]); return [{ episodeId: 21 }]; },
    prepareSeriesReleases: async (id, selection, options) => { calls.push(['series', id, selection, options]); return seriesEnvelope; },
  }));

  assert.deepEqual((await request(base, '/v1/movies/7/releases?freePublicDomain=true&refresh=true', { method: 'POST' })).body, movieEnvelope);
  assert.deepEqual((await request(base, '/v1/series/8/episodes', { method: 'POST' })).body, { items: [{ episodeId: 21 }], prepared: true });
  assert.deepEqual((await request(base, '/v1/series/8/releases?refresh=true', { method: 'POST', json: { seasonNumber: 0, freePublicDomain: true } })).body, seriesEnvelope);
  assert.deepEqual((await request(base, '/v1/series/8/releases', { method: 'POST', json: { episodeId: 21 } })).body, seriesEnvelope);
  assert.deepEqual(calls, [
    ['movie', '7', { freePublicDomain: true, force: true }],
    ['episodes', '8'],
    ['series', '8', { seasonNumber: 0, freePublicDomain: true }, { force: true }],
    ['series', '8', { episodeId: 21 }, { force: false }],
  ]);
});

test('rejects invalid series prepare scopes before calling media clients', async t => {
  let calls = 0;
  const base = await start(t, fakeMedia({ prepareSeriesReleases: async () => { calls += 1; return {}; } }));
  const invalid = [
    {},
    { seasonNumber: 1, episodeId: 2 },
    { seasonNumber: -1 },
    { seasonNumber: 1.5 },
    { seasonNumber: '1' },
    { episodeId: 0 },
    { episodeId: '2' },
    { seasonNumber: Number.MAX_SAFE_INTEGER + 1 },
    { episodeId: Number.MAX_SAFE_INTEGER + 1 },
    { seasonNumber: 1, freePublicDomain: 'true' },
  ];

  for (const value of invalid) {
    assert.deepEqual(
      await request(base, '/v1/series/8/releases', { method: 'POST', json: value }).then(({ status, body }) => ({ status, body })),
      { status: 400, body: { error: 'invalid_request' } },
    );
  }
  assert.equal(calls, 0);
});

test('rejects valid non-object JSON bodies before invoking handlers', async t => {
  let calls = 0;
  const base = await start(t, fakeMedia({ downloadRelease: async () => { calls += 1; return {}; } }));

  for (const raw of ['null', '[]', '"text"', '1', 'true']) {
    assert.deepEqual(
      await request(base, '/v1/movies/1/download', { method: 'POST', raw }).then(({ status, body }) => ({ status, body })),
      { status: 400, body: { error: 'invalid_request' } },
    );
  }
  assert.equal(calls, 0);
});

test('maps failures to stable public errors without leaking messages', async t => {
  const base = await start(t, fakeMedia({
    movie: async id => {
      if (id === '1') throw new Error('<html>secret upstream response</html>');
      const error = new Error(id === '2' ? 'socket timed out' : id === '3' ? 'already exists' : 'Movie not found');
      if (id === '2') error.code = 'upstream_timeout';
      if (id === '3') error.code = 'conflict';
      throw error;
    },
  }));

  assert.deepEqual(await request(base, '/v1/movies/1').then(({ status, body }) => ({ status, body })), { status: 502, body: { error: 'provider_unavailable' } });
  assert.deepEqual((await request(base, '/v1/movies/2')).body, { error: 'upstream_timeout' });
  assert.equal((await request(base, '/v1/movies/2')).status, 504);
  assert.deepEqual((await request(base, '/v1/movies/3')).body, { error: 'conflict' });
  assert.deepEqual((await request(base, '/v1/movies/4')).body, { error: 'not_found' });
  assert.deepEqual(await request(base, '/v1/movies/1/download', { method: 'POST', raw: '{' }).then(({ status, body }) => ({ status, body })), { status: 400, body: { error: 'invalid_request' } });
});

test('maps a JSON upstream deadline to 504', async t => {
  const upstream = http.createServer(() => {});
  upstream.listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  t.after(() => new Promise(resolve => {
    upstream.closeAllConnections();
    upstream.close(resolve);
  }));
  const upstreamUrl = `http://127.0.0.1:${upstream.address().port}`;
  const base = await start(t, fakeMedia({ movie: async () => jsonRequest(upstreamUrl, { timeoutMs: 5 }) }));

  assert.deepEqual(
    await request(base, '/v1/movies/1').then(({ status, body }) => ({ status, body })),
    { status: 504, body: { error: 'upstream_timeout' } },
  );
});

test('maps malformed JSON from an upstream provider to 502', async t => {
  const upstream = http.createServer((_req, res) => res.end('{'));
  upstream.listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  t.after(() => new Promise(resolve => upstream.close(resolve)));
  const upstreamUrl = `http://127.0.0.1:${upstream.address().port}`;
  const base = await start(t, fakeMedia({ movie: async () => jsonRequest(upstreamUrl) }));

  assert.deepEqual(
    await request(base, '/v1/movies/1').then(({ status, body }) => ({ status, body })),
    { status: 502, body: { error: 'provider_unavailable' } },
  );
});

test('maps invalid and expired subtitle tokens to 400', async t => {
  const server = createServer({ media: fakeMedia(), subtitleTokenSecret: 'test-secret' });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const expired = createSubtitleToken({ source: 'bazarr', mediaType: 'movie', selection: {} }, 'test-secret', 0);

  for (const downloadToken of ['invalid', expired]) {
    assert.deepEqual(
      await request(base, '/v1/library/1/subtitles/download', { method: 'POST', json: { downloadToken } }).then(({ status, body }) => ({ status, body })),
      { status: 400, body: { error: 'invalid_request' } },
    );
  }
});

test('maps local subtitle upload validation failures to 400', async t => {
  const media = new MediaClients({});
  media.managedMovie = async () => ({ movieFile: { path: 'C:\\media\\movie.mkv' } });
  const base = await start(t, media);

  assert.deepEqual(
    await request(base, '/v1/library/1/subtitles/upload', {
      method: 'POST',
      json: { fileName: 'subtitle.exe', contentBase64: 'AA==', language: 'vi' },
    }).then(({ status, body }) => ({ status, body })),
    { status: 400, body: { error: 'invalid_request' } },
  );
});

test('maps an existing atomic subtitle target to 409', async t => {
  const error = new Error('already exists');
  error.code = 'EEXIST';
  const base = await start(t, fakeMedia({ uploadLocalSubtitle: async () => { throw error; } }));

  assert.deepEqual(
    await request(base, '/v1/library/1/subtitles/upload', { method: 'POST', json: {} }).then(({ status, body }) => ({ status, body })),
    { status: 409, body: { error: 'conflict' } },
  );
});

test('body limit counts bytes, keeps the 7 MiB upload override, and omits wildcard CORS', async t => {
  let deleted = false;
  let uploaded = false;
  const base = await start(t, fakeMedia({
    deleteManagedMovie: async () => { deleted = true; return { deleted: true }; },
    uploadLocalSubtitle: async () => { uploaded = true; return { uploaded: true }; },
  }));
  const unicodePayload = { padding: '€'.repeat(350_000), deleteFiles: true, deleteTorrent: true };

  assert.deepEqual(await request(base, '/v1/library/1', { method: 'DELETE', json: unicodePayload }).then(({ status, body }) => ({ status, body })), { status: 413, body: { error: 'request_too_large' } });
  assert.equal(deleted, false);
  assert.equal((await request(base, '/v1/library/1/subtitles/upload', { method: 'POST', json: { padding: '€'.repeat(350_000) } })).status, 201);
  assert.equal(uploaded, true);
  assert.equal((await request(base, '/health')).headers.get('access-control-allow-origin'), null);
  assert.equal((await request(base, '/health', { method: 'OPTIONS' })).status, 204);
});

test('oversized slow uploads receive JSON 413 without resetting the client socket', async t => {
  let deleted = false;
  const base = await start(t, fakeMedia({ deleteManagedMovie: async () => { deleted = true; return {}; } }));

  assert.deepEqual(await slowChunkedRequest(base, '/v1/library/1', [
    Buffer.alloc(600 * 1024, 97),
    Buffer.alloc(600 * 1024, 98),
    Buffer.from('{}'),
  ]), { status: 413, body: { error: 'request_too_large' } });
  assert.equal(deleted, false);
});

test('keeps legacy download polling and exposes the injected SSE stream', async t => {
  const items = [{ hash: 'active', state: 'downloading', importStatus: 'downloading' }];
  const media = fakeMedia({ downloads: async () => items });
  const server = createServer({ media, downloadEvents: createDownloadEventsHub(() => media.downloads()) });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;

  assert.deepEqual((await request(base, '/v1/downloads')).body, items);
  const stream = await fetch(`${base}/v1/downloads/events`);
  assert.equal(stream.status, 200);
  assert.equal(stream.headers.get('content-type'), 'text/event-stream; charset=utf-8');
  assert.equal(stream.headers.get('cache-control'), 'no-cache');
  const reader = stream.body.getReader();
  let output = '';
  while (!output.includes('event: snapshot')) {
    const value = await reader.read();
    output += new TextDecoder().decode(value.value);
  }
  await reader.cancel();
  assert.match(output, /^retry: 3000\n\nevent: snapshot\ndata: /);
  assert.match(output, /"items":\[{"hash":"active"/);
});
