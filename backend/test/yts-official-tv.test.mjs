import test from 'node:test';
import assert from 'node:assert/strict';
import {
  YtsOfficialTvProvider,
  filterTvTorrents,
  normalizeSonarrTvRelease,
  normalizeTvTorrent,
} from '../src/yts-official-tv.mjs';

class MemoryStore {
  constructor(items = []) { this.items = items; }
  async read() { return this.items; }
  async write(items) { this.items = items; }
}

const magnet = hash => `magnet:?xt=urn:btih:${hash}&dn=Show`;

test('season filtering accepts only the exact pack and rejects collections or episodes', () => {
  const rows = [
    { title: 'Show S02 1080p WEB-DL', magnetUrl: magnet('A'.repeat(40)) },
    { title: 'Show Season 2 Complete 720p', magnetUrl: magnet('B'.repeat(40)) },
    { title: 'Show S01-S05 1080p', magnetUrl: magnet('C'.repeat(40)) },
    { title: 'Show S02E03 1080p', magnetUrl: magnet('D'.repeat(40)) },
    { title: 'Show S03 1080p', magnetUrl: magnet('E'.repeat(40)) },
  ];
  assert.deepEqual(filterTvTorrents(rows, { seasonNumber: 2 }).map(row => row.title), [
    'Show S02 1080p WEB-DL',
    'Show Season 2 Complete 720p',
  ]);
});

test('episode filtering accepts only the exact selected episode', () => {
  const rows = [
    { title: 'Show S02E03 1080p', magnetUrl: magnet('A'.repeat(40)) },
    { title: 'Show 2x03 720p', magnetUrl: magnet('B'.repeat(40)) },
    { title: 'Show S02E04 1080p', magnetUrl: magnet('C'.repeat(40)) },
    { title: 'Show S02 Complete', magnetUrl: magnet('D'.repeat(40)) },
  ];
  assert.deepEqual(filterTvTorrents(rows, { seasonNumber: 2, episodeNumber: 3 }).map(row => row.title), [
    'Show S02E03 1080p',
    'Show 2x03 720p',
  ]);
});

test('normalization exposes an opaque token but never the magnet', () => {
  const release = normalizeTvTorrent({
    title: 'Show S02E03 1080p x265', bytes: 123, seeders: 7, peers: 9,
    magnetUrl: magnet('ABCDEF0123456789ABCDEF0123456789ABCDEF01'),
  }, { tvdbId: 123, seasonNumber: 2, episodeNumber: 3 }, 'secret', 1000);
  assert.equal(release.source, 'YTS Official');
  assert.equal(release.codec, 'H.265');
  assert.equal(release.size, 123);
  assert.equal(typeof release.downloadToken, 'string');
  assert.equal('magnetUrl' in release, false);
  assert.doesNotMatch(JSON.stringify(release), /magnet:\?/);
});

test('provider verifies same-scope tokens and rejects tampering or cross-scope reuse', () => {
  const provider = new YtsOfficialTvProvider({ baseUrl: 'https://en.yts-official.com/', secret: 'secret', now: () => 1000 });
  const release = normalizeTvTorrent({ title: 'Show S02E03', magnetUrl: magnet('ABCDEF0123456789ABCDEF0123456789ABCDEF01') }, { tvdbId: 123, seasonNumber: 2, episodeNumber: 3 }, 'secret', 1000);
  assert.equal(provider.resolveToken(release.downloadToken, { tvdbId: 123, seasonNumber: 2, episodeNumber: 3 }).infoHash, 'abcdef0123456789abcdef0123456789abcdef01');
  assert.throws(() => provider.resolveToken(`${release.downloadToken}x`, { tvdbId: 123, seasonNumber: 2, episodeNumber: 3 }), /invalid_download_token/);
  assert.throws(() => provider.resolveToken(release.downloadToken, { tvdbId: 123, seasonNumber: 2, episodeNumber: 4 }), /invalid_download_token/);
});

test('normalizes a Sonarr fallback release behind the same opaque token contract', () => {
  const release = normalizeSonarrTvRelease({
    guid: 'sonarr-guid', indexerId: 7, indexer: 'EZTV', title: 'Show S02E03 1080p',
    size: 1234, seeders: 9, peers: 12, quality: { quality: { name: 'WEBDL-1080p' } },
  }, { tvdbId: 123, seasonNumber: 2, episodeNumber: 3 }, 'secret', 1000);
  assert.equal(release.source, 'EZTV');
  assert.equal(release.sourceMode, 'prowlarr');
  assert.equal(release.fallbackUsed, true);
  assert.equal('guid' in release, false);
  const provider = new YtsOfficialTvProvider({ secret: 'secret', now: () => 1000 });
  assert.deepEqual(provider.resolveToken(release.downloadToken, { tvdbId: 123, seasonNumber: 2, episodeNumber: 3 }), {
    sourceMode: 'prowlarr', guid: 'sonarr-guid', indexerId: 7, title: 'Show S02E03 1080p', infoHash: null,
  });
});

test('provider searches the public TV endpoint and returns only normalized exact releases', async () => {
  let requested;
  const provider = new YtsOfficialTvProvider({
    baseUrl: 'https://en.yts-official.com/', secret: 'secret',
    fetchImpl: async url => {
      requested = new URL(url);
      return new Response(JSON.stringify({ hits: [
        { title: 'Show S01 1080p', magnetUrl: magnet('A'.repeat(40)) },
        { title: 'Show S01E01 1080p', magnetUrl: magnet('B'.repeat(40)) },
      ] }), { status: 200, headers: { 'content-type': 'application/json' } });
    },
  });
  const releases = await provider.search({ tvdbId: 123, title: 'Show', year: 2024, seasonNumber: 1 });
  assert.equal(requested.searchParams.get('api'), 'torrents');
  assert.equal(requested.searchParams.get('mode'), 'tv');
  assert.equal(releases.length, 1);
  assert.equal(releases[0].title, 'Show S01 1080p');
});

test('provider treats a successful empty search as ready with no releases', async () => {
  const provider = new YtsOfficialTvProvider({
    secret: 'secret',
    fetchImpl: async () => new Response('{"hits":[]}', { status: 200, headers: { 'content-type': 'application/json' } }),
  });
  assert.deepEqual(await provider.search({ title: 'Show', year: 2024, seasonNumber: 1 }), []);
});

test('provider forwards caller cancellation to its HTTP request', async () => {
  let requestSignal;
  const provider = new YtsOfficialTvProvider({
    secret: 'secret',
    timeoutMs: 50,
    fetchImpl: async (_url, { signal }) => {
      requestSignal = signal;
      return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
    },
  });
  const controller = new AbortController();
  const pending = provider.search({ tvdbId: 123, title: 'Show', year: 2024, seasonNumber: 1 }, { signal: controller.signal });
  const reason = new Error('source_timeout');
  controller.abort(reason);

  await assert.rejects(pending, /yts_tv_provider_unavailable/);
  assert.equal(requestSignal.aborted, true);
  assert.equal(requestSignal.reason, reason);
});

test('provider preserves its own upstream timeout code', async () => {
  const provider = new YtsOfficialTvProvider({
    secret: 'secret',
    timeoutMs: 5,
    fetchImpl: async (_url, { signal }) => new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    }),
  });

  await assert.rejects(provider.search({ title: 'Show', year: 2024, seasonNumber: 1 }), error => {
    assert.equal(error.code, 'upstream_timeout');
    return true;
  });
});

test('TV trending uses primary trending then stores normalized cards', async () => {
  const requested = [];
  const provider = new YtsOfficialTvProvider({
    baseUrl: 'https://en.yts-official.com/', secret: 'secret', store: new MemoryStore(),
    fetchImpl: async url => {
      requested.push(new URL(url));
      return new Response(JSON.stringify({ results: [{ id: 44, name: 'Trending Show', first_air_date: '2025-01-02', overview: 'Overview', poster_path: '/poster.jpg', vote_average: 8.2 }] }), { status: 200, headers: { 'content-type': 'application/json' } });
    },
  });
  const result = await provider.trending();
  assert.equal(requested[0].searchParams.get('api'), 'trending');
  assert.deepEqual(result, { items: [{ mediaType: 'series', providerId: 44, tvdbId: null, title: 'Trending Show', year: 2025, overview: 'Overview', poster: 'https://image.tmdb.org/t/p/w500/poster.jpg', rating: 8.2, inLibrary: false }], stale: false, source: 'yts_official' });
});

test('TV trending falls back to popular then cache without exposing provider fields', async () => {
  const store = new MemoryStore();
  let calls = 0;
  const provider = new YtsOfficialTvProvider({
    baseUrl: 'https://en.yts-official.com/', secret: 'secret', store,
    fetchImpl: async () => {
      calls++;
      if (calls === 1) return new Response(JSON.stringify({ results: [] }), { status: 200, headers: { 'content-type': 'application/json' } });
      if (calls === 2) return new Response(JSON.stringify({ results: [{ id: 8, title: 'Popular Show', first_air_date: '2024-05-01', magnetUrl: 'hidden' }] }), { status: 200, headers: { 'content-type': 'application/json' } });
      throw new Error('offline');
    },
  });
  const popular = await provider.trending();
  assert.equal(popular.source, 'popular');
  assert.equal('magnetUrl' in popular.items[0], false);
  const cached = await provider.trending();
  assert.deepEqual(cached, { items: popular.items, stale: true, source: 'cache' });
});
