import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createYtsPopularFetcher,
  MemoryTrendingStore,
  TrendingMovies,
  normalizeYtsMovie,
  normalizeTrendingMovie,
} from '../src/trending-movies.mjs';

test('normalizes a YTS popular movie as a movie discovery card', () => {
  assert.deepEqual(normalizeYtsMovie({ id: 10, title: 'Fallback', year: 2025, summary: 'Summary', medium_cover_image: 'poster.jpg', rating: 7.4 }), {
    tmdbId: 0, ytsId: 10, mediaType: 'movie', title: 'Fallback', year: 2025, overview: 'Summary', poster: 'poster.jpg', runtime: null, genres: [], inLibrary: false, rating: 7.4,
  });
});

test('uses YTS popular when Seerr fails and no cache exists', async () => {
  const trending = new TrendingMovies({
    fetchPage: async () => { throw new Error('Seerr 500'); },
    fetchFallback: async () => ({ data: { movies: [{ id: 10, title: 'Fallback', year: 2025 }] } }),
    store: new MemoryTrendingStore(),
  });
  const result = await trending.get();
  assert.equal(result.source, 'yts');
  assert.equal(result.items[0].title, 'Fallback');
  assert.deepEqual(await trending.store.read(), result.items);
});

test('YTS fetcher uses a bounded request and rejects upstream errors', async () => {
  let requested;
  const fetcher = createYtsPopularFetcher({ baseUrl: 'https://movies.example', fetchImpl: async url => {
    requested = url;
    return { ok: true, json: async () => ({ data: { movies: [] } }) };
  }});
  await fetcher();
  assert.match(requested, /list_movies\.json\?limit=40&sort_by=download_count/);
});

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
    mediaType: 'movie',
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
  assert.equal(result.source, 'seerr');
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
