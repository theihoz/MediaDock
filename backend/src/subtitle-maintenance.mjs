function numberOr(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

async function mapLimit(items, limit, mapper) {
  const results = new Array(items.length);
  let cursor = 0;
  const worker = async () => {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await mapper(items[index], index);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

export function createSubtitleMaintenance({
  media,
  enabled = true,
  intervalMs = 6 * 60 * 60 * 1000,
  maxItems = 50,
  concurrency = 2,
  now = Date.now,
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
} = {}) {
  const config = {
    enabled: Boolean(enabled),
    intervalMs: Math.max(1000, numberOr(intervalMs, 6 * 60 * 60 * 1000)),
    maxItems: Math.max(1, Math.floor(numberOr(maxItems, 50))),
    concurrency: Math.max(1, Math.floor(numberOr(concurrency, 2))),
  };
  let pending = null;
  let timer = null;
  const status = {
    enabled: config.enabled,
    state: 'idle',
    lastStartedAt: null,
    lastFinishedAt: null,
    nextRunAt: null,
    result: null,
  };

  async function processMovie(movie) {
    const result = await media.searchSubtitles(movie.mediaId, 'vi');
    const candidates = [...(result?.data ?? result ?? [])]
      .filter(item => (item.language ?? item.code2 ?? item.lang) === 'vi')
      .sort((left, right) => Number(right.score ?? 0) - Number(left.score ?? 0));
    if (!candidates[0]) return { state: 'unavailable', mediaId: movie.mediaId, type: 'movie' };
    await media.downloadSubtitle(movie.mediaId, candidates[0]);
    await media.refreshSubtitles(movie.mediaId).catch(() => null);
    return { state: 'downloaded', mediaId: movie.mediaId, type: 'movie' };
  }

  async function processEpisode(episode) {
    const result = await media.searchEpisodeSubtitles(episode.mediaId, 'vi');
    const candidates = [...(result?.data ?? result ?? [])]
      .filter(item => (item.language ?? item.code2 ?? item.lang) === 'vi')
      .sort((left, right) => Number(right.score ?? 0) - Number(left.score ?? 0));
    if (!candidates[0]) return { state: 'unavailable', mediaId: episode.mediaId, type: 'episode' };
    await media.downloadEpisodeSubtitle(episode.mediaId, candidates[0]);
    await media.refreshEpisodeSubtitles(episode.mediaId).catch(() => null);
    return { state: 'downloaded', mediaId: episode.mediaId, type: 'episode' };
  }

  async function execute() {
    const catalog = await media.subtitleMedia();
    const movies = catalog.filter(item => item.type === 'movie' && item.hasVietnamese === false);
    const seasons = catalog
      .filter(item => item.type === 'series')
      .flatMap(series => (series.seasons ?? [])
        .filter(season => season.viMissing > 0)
        .map(season => ({ seriesId: series.mediaId, seasonNumber: season.seasonNumber })));
    const work = [];
    for (const movie of movies) {
      if (work.length >= config.maxItems) break;
      work.push({ kind: 'movie', value: movie });
    }
    for (const season of seasons) {
      if (work.length >= config.maxItems) break;
      const episodes = await media.subtitleSeason(season.seriesId, season.seasonNumber);
      for (const episode of episodes.filter(item => !item.hasVietnamese)) {
        if (work.length >= config.maxItems) break;
        work.push({ kind: 'episode', value: episode });
      }
    }

    const results = await mapLimit(work, config.concurrency, async item => {
      try {
        return await (item.kind === 'movie' ? processMovie(item.value) : processEpisode(item.value));
      } catch (error) {
        return { state: 'failed', mediaId: item.value.mediaId, type: item.kind, error: error?.code ?? 'provider_unavailable' };
      }
    });
    const downloaded = results.filter(item => item.state === 'downloaded').length;
    if (downloaded > 0) await media.refreshJellyfin().catch(() => null);
    return {
      scanned: catalog.length,
      queued: work.length,
      downloaded,
      unavailable: results.filter(item => item.state === 'unavailable').length,
      failed: results.filter(item => item.state === 'failed').length,
    };
  }

  function run() {
    if (!config.enabled) return Promise.resolve({ state: 'disabled' });
    if (pending) return pending;
    status.state = 'running';
    status.lastStartedAt = now();
    status.nextRunAt = null;
    pending = execute()
      .then(result => {
        status.result = result;
        return result;
      })
      .finally(() => {
        status.state = 'idle';
        status.lastFinishedAt = now();
        status.nextRunAt = now() + config.intervalMs;
        pending = null;
      });
    return pending;
  }

  function start() {
    if (timer || !config.enabled) return;
    status.nextRunAt = now();
    void run().catch(() => null);
    timer = setIntervalFn(() => { void run(); }, config.intervalMs);
  }

  function stop() {
    if (!timer) return;
    clearIntervalFn(timer);
    timer = null;
  }

  return {
    run,
    start,
    stop,
    status: () => ({ ...status, result: status.result ? { ...status.result } : null }),
  };
}
