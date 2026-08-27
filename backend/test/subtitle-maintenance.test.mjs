import assert from 'node:assert/strict';
import test from 'node:test';
import { createSubtitleMaintenance } from '../src/subtitle-maintenance.mjs';

function fakeMedia(overrides = {}) {
  return {
    subtitleMedia: async () => [],
    subtitleSeason: async () => [],
    searchSubtitles: async () => ({ data: [] }),
    downloadSubtitle: async () => null,
    refreshSubtitles: async () => null,
    searchEpisodeSubtitles: async () => ({ data: [] }),
    downloadEpisodeSubtitle: async () => null,
    refreshEpisodeSubtitles: async () => null,
    refreshJellyfin: async () => null,
    ...overrides,
  };
}

test('downloads the best Vietnamese subtitle for missing movies and episodes', async () => {
  const downloads = [];
  const media = fakeMedia({
    subtitleMedia: async () => [{ mediaId: 7, type: 'movie', hasVietnamese: false }, {
      mediaId: 21, type: 'series', seasons: [{ seasonNumber: 1, viMissing: 1 }],
    }],
    subtitleSeason: async () => [{ mediaId: 91, hasVietnamese: false }],
    searchSubtitles: async () => ({ data: [{ language: 'vi', score: 60 }, { language: 'vi', score: 95 }] }),
    searchEpisodeSubtitles: async () => ({ data: [{ language: 'vi', score: 70 }, { language: 'vi', score: 90 }] }),
    downloadSubtitle: async (id, value) => downloads.push(['movie', id, value.score]),
    downloadEpisodeSubtitle: async (id, value) => downloads.push(['episode', id, value.score]),
  });
  const maintenance = createSubtitleMaintenance({ media, intervalMs: 1000 });

  assert.deepEqual(await maintenance.run(), { scanned: 2, queued: 2, downloaded: 2, unavailable: 0, failed: 0 });
  assert.deepEqual(downloads, [['movie', 7, 95], ['episode', 91, 90]]);
  assert.equal(maintenance.status().state, 'idle');
});

test('coalesces concurrent scans and respects the batch limit', async () => {
  let release;
  const media = fakeMedia({
    subtitleMedia: async () => [
      { mediaId: 1, type: 'movie', hasVietnamese: false },
      { mediaId: 2, type: 'movie', hasVietnamese: false },
      { mediaId: 3, type: 'movie', hasVietnamese: false },
    ],
    searchSubtitles: async () => new Promise(resolve => { release = resolve; }),
  });
  const maintenance = createSubtitleMaintenance({ media, maxItems: 2, concurrency: 1, intervalMs: 1000 });
  const first = maintenance.run();
  const second = maintenance.run();
  assert.equal(first, second);
  await new Promise(resolve => setImmediate(resolve));
  release({ data: [{ language: 'vi', score: 80 }] });
  const result = await first;
  assert.equal(result.queued, 2);
});

test('does nothing when disabled', async () => {
  let calls = 0;
  const maintenance = createSubtitleMaintenance({ enabled: false, media: fakeMedia({ subtitleMedia: async () => { calls++; return []; } }) });
  assert.deepEqual(await maintenance.run(), { state: 'disabled' });
  assert.equal(calls, 0);
  assert.equal(maintenance.status().enabled, false);
});
