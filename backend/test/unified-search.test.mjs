import test from 'node:test';
import assert from 'node:assert/strict';
import { UnifiedSearch, normalizeQuery } from '../src/unified-search.mjs';

test('normalizes accents, punctuation, and whitespace for matching', () => {
  assert.equal(normalizeQuery('  Đạo-diễn:  Sam  Raimi '), 'dao dien sam raimi');
});

test('does not call providers for queries shorter than two characters', async () => {
  const search = new UnifiedSearch({ movieSearch: () => assert.fail(), seriesSearch: () => assert.fail() });
  assert.deepEqual(await search.search({ query: 'a' }), { items: [], partial: false, sources: {}, query: 'a' });
});

test('merges concurrent movie and series results and deduplicates aliases', async () => {
  const search = new UnifiedSearch({
    movieSearch: async () => [
      { tmdbId: 1, title: 'Doctor Strange', aliases: ['Phù Thủy Tối Thượng'], year: 2016 },
      { tmdbId: 1, title: 'Doctor Strange', aliases: ['Doctor Strange'], year: 2016 },
    ],
    seriesSearch: async () => [{ tvdbId: 2, title: 'Mushoku Tensei', aliases: ['Jobless Reincarnation'], year: 2021 }],
  });
  const result = await search.search({ query: 'strange' });
  assert.equal(result.items.length, 2);
  assert.deepEqual(result.items.map(item => item.mediaType), ['movie', 'series']);
  assert.equal(result.items[0].matchedBy, 'title');
});

test('matches aliases, studio, network, and people and reports why', async () => {
  const rows = [{
    tmdbId: 1, title: 'Doctor Strange', aliases: ['Phù Thủy Tối Thượng'], studios: ['Marvel Studios'],
    people: ['Benedict Cumberbatch'], year: 2016, inLibrary: true,
  }];
  for (const [query, matchedBy] of [['phu thuy toi thuong', 'alias'], ['marvel studios', 'studio'], ['benedict', 'person']]) {
    const search = new UnifiedSearch({ movieSearch: async () => rows, seriesSearch: async () => [] });
    const result = await search.search({ query });
    assert.equal(result.items[0].matchedBy, matchedBy);
  }
});

test('returns partial results when one provider fails and applies filters', async () => {
  const search = new UnifiedSearch({
    movieSearch: async () => [{ tmdbId: 1, title: 'Movie', year: 2022, inLibrary: true }],
    seriesSearch: async () => { throw new Error('offline'); },
  });
  const result = await search.search({ query: 'movie', type: 'all', year: 2022, library: 'in' });
  assert.equal(result.partial, true);
  assert.equal(result.items.length, 1);
  assert.equal(result.sources.series, 'failed');
});

test('caches and coalesces identical concurrent searches', async () => {
  let calls = 0;
  let release;
  const pending = new Promise(resolve => { release = resolve; });
  const search = new UnifiedSearch({ movieSearch: async () => { calls++; await pending; return []; }, seriesSearch: async () => [] });
  const first = search.search({ query: 'matrix' });
  const second = search.search({ query: 'matrix' });
  release();
  await Promise.all([first, second]);
  await search.search({ query: 'matrix' });
  assert.equal(calls, 1);
});

test('prunes expired searches and caps the cache', async () => {
  let now = 0;
  let calls = 0;
  const search = new UnifiedSearch({
    movieSearch: async query => { calls += 1; return [{ tmdbId: calls, title: query }]; },
    seriesSearch: async () => [],
    ttlMs: 100,
    maxEntries: 2,
    now: () => now,
  });

  await search.search({ query: 'one', type: 'movie' });
  await search.search({ query: 'two', type: 'movie' });
  await search.search({ query: 'three', type: 'movie' });
  assert.equal(search.cache.size, 2);
  await search.search({ query: 'one', type: 'movie' });
  assert.equal(calls, 4);

  now = 101;
  await search.search({ query: 'four', type: 'movie' });
  assert.equal(search.cache.size, 1);
});

test('clears provider timeout handles after successful searches', async t => {
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  const handles = [];
  const cleared = [];
  t.after(() => {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  });
  globalThis.setTimeout = (callback, delay) => {
    const handle = { callback, delay };
    handles.push(handle);
    return handle;
  };
  globalThis.clearTimeout = handle => cleared.push(handle);

  const search = new UnifiedSearch({ movieSearch: async () => [], seriesSearch: async () => [] });
  await search.search({ query: 'matrix' });
  assert.equal(handles.length, 2);
  assert.deepEqual(cleared, handles);
});
