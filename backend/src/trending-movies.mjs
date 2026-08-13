import fs from 'node:fs/promises';
import path from 'node:path';

const posterBase = 'https://image.tmdb.org/t/p/w500';

export function normalizeTrendingMovie(value) {
  const releaseDate = value.releaseDate ?? value.release_date ?? '';
  const posterPath = value.posterPath ?? value.poster_path;
  return {
    tmdbId: Number(value.id),
    mediaType: 'movie',
    title: value.title ?? value.name ?? '',
    year: /^\d{4}/.test(releaseDate) ? Number(releaseDate.slice(0, 4)) : null,
    overview: value.overview ?? '',
    poster: posterPath ? `${posterBase}${posterPath}` : null,
    runtime: Number.isFinite(value.runtime) ? value.runtime : null,
    genres: Array.isArray(value.genres) ? value.genres.map(item => item.name ?? item).filter(Boolean) : [],
    inLibrary: Boolean(value.mediaInfo),
    rating: Number(value.voteAverage ?? value.vote_average ?? 0),
  };
}

export function normalizeYtsMovie(value) {
  return {
    tmdbId: 0,
    ytsId: Number(value.id),
    mediaType: 'movie',
    title: value.title ?? '',
    year: Number(value.year ?? 0),
    overview: value.summary ?? value.description_full ?? '',
    poster: value.medium_cover_image ?? null,
    runtime: Number.isFinite(value.runtime) ? value.runtime : null,
    genres: Array.isArray(value.genres) ? value.genres : [],
    inLibrary: false,
    rating: Number(value.rating ?? 0),
  };
}

export class MemoryTrendingStore {
  constructor(items = []) { this.items = items; }
  async read() { return this.items; }
  async write(items) { this.items = items; }
}

export class JsonTrendingStore {
  constructor(filePath) { this.filePath = filePath; }
  async read() {
    try {
      const value = JSON.parse(await fs.readFile(this.filePath, 'utf8'));
      return Array.isArray(value) ? value : [];
    } catch {
      return [];
    }
  }
  async write(items) {
    await fs.mkdir(path.dirname(this.filePath), { recursive: true });
    const temporary = `${this.filePath}.${process.pid}.tmp`;
    await fs.writeFile(temporary, JSON.stringify(items), { mode: 0o600 });
    await fs.rename(temporary, this.filePath);
  }
}

export class TrendingMovies {
  constructor({ fetchPage, fetchFallback, store, limit = 40 }) {
    this.fetchPage = fetchPage;
    this.store = store;
    this.fetchFallback = fetchFallback;
    this.limit = limit;
  }

  async get() {
    try {
      const page = await this.fetchPage();
      const items = (page?.results ?? [])
        .map(normalizeTrendingMovie)
        .filter(item => item.tmdbId > 0 && item.title)
        .slice(0, this.limit);
      if (items.length > 0) {
        await this.store.write(items);
        return { items, source: 'seerr', stale: false };
      }
    } catch {
      // The public response intentionally falls back without upstream details.
    }
    const cached = await this.store.read();
    if (cached.length > 0) return { items: cached, source: 'cache', stale: true };
    if (this.fetchFallback) {
      try {
        const page = await this.fetchFallback();
        const items = (page?.data?.movies ?? []).map(normalizeYtsMovie)
          .filter(item => item.ytsId > 0 && item.title).slice(0, this.limit);
        if (items.length > 0) {
          await this.store.write(items);
          return { items, source: 'yts', stale: false };
        }
      } catch {}
    }
    return { items: [], source: 'unavailable', stale: false };
  }
}

export function createYtsPopularFetcher({ baseUrl, fetchImpl = fetch }) {
  return async () => {
    const response = await fetchImpl(`${baseUrl.replace(/\/$/, '')}/api/v2/list_movies.json?limit=40&sort_by=download_count`, {
      headers: { accept: 'application/json' }, signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) throw new Error(`YTS discovery failed with ${response.status}`);
    return response.json();
  };
}

export async function readSeerrApiKey(configPath) {
  const config = JSON.parse(await fs.readFile(configPath, 'utf8'));
  const apiKey = config?.main?.apiKey ?? config?.apiKey;
  if (!apiKey) throw new Error('Seerr API key is unavailable');
  return apiKey;
}

export function createSeerrFetcher({ baseUrl, configPath, fetchImpl = fetch }) {
  return async () => {
    const apiKey = await readSeerrApiKey(configPath);
    const response = await fetchImpl(`${baseUrl}/api/v1/discover/movies?page=1&sortBy=popularity.desc`, {
      headers: { 'x-api-key': apiKey, accept: 'application/json' },
    });
    if (!response.ok) throw new Error(`Seerr discovery failed with ${response.status}`);
    return response.json();
  };
}
