import test from 'node:test';
import assert from 'node:assert/strict';

import {
  MemoryTrendingStore,
  TrendingMovies,
  normalizeTrendingMovie,
} from '../src/trending-movies.mjs';

test('normalizes Seerr discovery without exposing provider fields', () => {
  assert.deepEqual(normalizeTrendingMovie({
    id: 603,
    title: 'The Matrix',
    releaseDate: '1999-03-30',
    overview: 'A hacker discovers the truth.',
    posterPath: '/poster.jpg',
    genreIds: [28],
    mediaInfo: { id: 7 },
    voteAverage: 8.2,
    popularity: 999,
  }), {
    tmdbId: 603,
    title: 'The Matrix',
    year: 1999,
    overview: 'A hacker discovers the truth.',
    poster: 'https://image.tmdb.org/t/p/w500/poster.jpg',
    runtime: null,
    genres: [],
    inLibrary: true,
    rating: 8.2,
  });
});

test('stores a bounded normalized live result', async () => {
  const store = new MemoryTrendingStore();
  const trending = new TrendingMovies({
    fetchPage: async () => ({ results: Array.from({ length: 45 }, (_, index) => ({ id: index + 1, title: `Movie ${index + 1}` })) }),
    store,
  });

  const result = await trending.get();
  assert.equal(result.source, 'live');
  assert.equal(result.stale, false);
  assert.equal(result.items.length, 40);
  assert.deepEqual(await store.read(), result.items);
});

test('returns last-good cache when Seerr is unavailable', async () => {
  const cached = [{ tmdbId: 603, title: 'Cached' }];
  const trending = new TrendingMovies({
    fetchPage: async () => { throw new Error('secret upstream response'); },
    store: new MemoryTrendingStore(cached),
  });

  assert.deepEqual(await trending.get(), { items: cached, source: 'cache', stale: true });
});

test('returns a normalized unavailable state without live or cached data', async () => {
  const trending = new TrendingMovies({
    fetchPage: async () => { throw new Error('connect ECONNREFUSED 5055'); },
    store: new MemoryTrendingStore(),
  });

  assert.deepEqual(await trending.get(), { items: [], source: 'unavailable', stale: false });
});
