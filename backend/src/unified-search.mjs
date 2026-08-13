export function normalizeQuery(value) {
  return String(value ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/đ/gi, match => match === 'Đ' ? 'D' : 'd')
    .toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' ');
}

function textMatch(values, query) {
  return (Array.isArray(values) ? values : [values]).find(value => normalizeQuery(value).includes(query));
}

function normalizeItem(value, mediaType, query) {
  const aliases = [...new Set([...(value.aliases ?? []), value.originalTitle].filter(Boolean))];
  const studios = value.studios ?? [];
  const networks = value.networks ?? (value.network ? [value.network] : []);
  const people = value.people ?? [];
  let matchedBy = 'title';
  let matchedText = textMatch([value.title], query) ?? value.title;
  if (!textMatch([value.title], query)) {
    for (const [kind, values] of [['alias', aliases], ['person', people], ['studio', studios], ['network', networks]]) {
      const match = textMatch(values, query);
      if (match) { matchedBy = kind; matchedText = match; break; }
    }
  }
  return {
    ...value, mediaType, aliases, studios, networks, people, matchedBy, matchedText,
  };
}

function bounded(promise, timeoutMs) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('provider_timeout')), timeoutMs)),
  ]);
}

export class UnifiedSearch {
  constructor({ movieSearch, seriesSearch, ttlMs = 5 * 60 * 1000, timeoutMs = 3500, now = Date.now }) {
    this.movieSearch = movieSearch;
    this.seriesSearch = seriesSearch;
    this.ttlMs = ttlMs;
    this.timeoutMs = timeoutMs;
    this.now = now;
    this.cache = new Map();
    this.inFlight = new Map();
  }

  async search({ query, type = 'all', year, library = 'all', limit = 50 }) {
    const originalQuery = String(query ?? '').trim();
    const normalized = normalizeQuery(originalQuery);
    if (normalized.length < 2) return { items: [], partial: false, sources: {}, query: originalQuery };
    const key = JSON.stringify([normalized, type, Number(year) || 0, library, Number(limit) || 50]);
    const cached = this.cache.get(key);
    if (cached && cached.expiresAt > this.now()) return cached.value;
    if (this.inFlight.has(key)) return this.inFlight.get(key);
    const pending = this.load({ originalQuery, normalized, type, year, library, limit })
      .then(value => { this.cache.set(key, { value, expiresAt: this.now() + this.ttlMs }); return value; })
      .finally(() => this.inFlight.delete(key));
    this.inFlight.set(key, pending);
    return pending;
  }

  async load({ originalQuery, normalized, type, year, library, limit }) {
    const requests = [];
    if (type === 'all' || type === 'movie') requests.push(['movie', this.movieSearch(originalQuery)]);
    if (type === 'all' || type === 'series') requests.push(['series', this.seriesSearch(originalQuery)]);
    const settled = await Promise.all(requests.map(async ([kind, promise]) => {
      try { return [kind, 'ready', await bounded(Promise.resolve(promise), this.timeoutMs)]; }
      catch { return [kind, 'failed', []]; }
    }));
    const sources = Object.fromEntries(settled.map(([kind, status]) => [kind, status]));
    const values = settled.flatMap(([kind, , rows]) => rows.map(row => normalizeItem(row, kind, normalized)));
    const deduped = [...new Map(values.map(item => [`${item.mediaType}:${item.tmdbId ?? item.tvdbId}`, item])).values()];
    const items = deduped.filter(item => (!year || Number(item.year) === Number(year)) &&
      (library === 'all' || (library === 'in') === Boolean(item.inLibrary))).slice(0, Math.min(50, Math.max(1, Number(limit) || 50)));
    return { items, partial: Object.values(sources).includes('failed'), sources, query: originalQuery };
  }
}
