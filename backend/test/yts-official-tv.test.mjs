import test from 'node:test';
import assert from 'node:assert/strict';
import {
  YtsOfficialTvProvider,
  filterTvTorrents,
  normalizeTvTorrent,
} from '../src/yts-official-tv.mjs';

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
