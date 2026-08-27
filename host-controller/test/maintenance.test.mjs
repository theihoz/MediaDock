import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { MaintenanceCleaner, handleMaintenanceRequest, startMaintenanceSchedule } from '../src/maintenance.mjs';

async function fixture() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'media-maintenance-'));
  const files = {
    oldCache: path.join(root, 'cache', 'jellyfin', 'old.bin'),
    newCache: path.join(root, 'cache', 'jellyfin', 'new.bin'),
    trending: path.join(root, 'cache', 'trending.json'),
    trendingTv: path.join(root, 'cache', 'trending-tv.json'),
    oldLog: path.join(root, 'config', 'radarr', 'logs', 'old.log'),
    retiredAutobrrLog: path.join(root, 'config', 'autobrr', 'logs', 'keep.log'),
    config: path.join(root, 'config', 'radarr', 'config.xml'),
    media: path.join(root, 'library', 'movies', 'movie.mkv'),
  };
  for (const file of Object.values(files)) {
    await fs.mkdir(path.dirname(file), { recursive: true });
    await fs.writeFile(file, '1234');
  }
  const old = new Date('2026-08-11T00:00:00Z');
  await fs.utimes(files.oldCache, old, old);
  await fs.utimes(files.oldLog, old, old);
  await fs.utimes(files.retiredAutobrrLog, old, old);
  return { root, files };
}

async function exists(file) {
  try { await fs.stat(file); return true; } catch { return false; }
}

test('scheduled cleanup deletes only allowlisted files older than 24 hours', async t => {
  const { root, files } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const cleaner = new MaintenanceCleaner({ mediaRoot: root, now: () => new Date('2026-08-13T00:00:00Z') });

  const result = await cleaner.cleanup({ force: false });

  assert.equal(result.removedFiles, 2);
  assert.equal(result.reclaimedBytes, 8);
  assert.equal(await exists(files.oldCache), false);
  assert.equal(await exists(files.oldLog), false);
  assert.equal(await exists(files.retiredAutobrrLog), true);
  assert.equal(await exists(files.newCache), true);
  assert.equal(await exists(files.trending), true);
  assert.equal(await exists(files.trendingTv), true);
  assert.equal(await exists(files.config), true);
  assert.equal(await exists(files.media), true);
});

test('manual cleanup removes new disposable files but preserves trending cache', async t => {
  const { root, files } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const cleaner = new MaintenanceCleaner({ mediaRoot: root, now: () => new Date('2026-08-13T00:00:00Z') });

  const result = await cleaner.cleanup({ force: true });

  assert.equal(result.removedFiles, 3);
  assert.equal(await exists(files.newCache), false);
  assert.equal(await exists(files.trending), true);
  assert.equal(await exists(files.trendingTv), true);
  assert.equal(await exists(files.config), true);
  assert.equal(await exists(files.retiredAutobrrLog), true);
});

test('maintenance schedule runs immediately without starting the media stack', async () => {
  let cleanups = 0;
  let scheduledMs = 0;
  const timer = { unrefCalled: false, unref() { this.unrefCalled = true; } };
  const cleaner = { cleanup: async ({ force }) => { assert.equal(force, false); cleanups++; } };
  const schedule = (callback, milliseconds) => { scheduledMs = milliseconds; return timer; };

  startMaintenanceSchedule(cleaner, { schedule });
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(cleanups, 1);
  assert.equal(scheduledMs, 60 * 60 * 1000);
  assert.equal(timer.unrefCalled, true);
});

test('maintenance API exposes status and forces manual cleanup', async () => {
  let forced = null;
  const cleaner = {
    status: () => ({ lastRunAt: null, removedFiles: 0 }),
    cleanup: async options => { forced = options.force; return { removedFiles: 4, reclaimedBytes: 1024 }; },
  };

  assert.deepEqual(await handleMaintenanceRequest('GET', '/host/maintenance/status', cleaner), {
    status: 200, body: { lastRunAt: null, removedFiles: 0 },
  });
  assert.deepEqual(await handleMaintenanceRequest('POST', '/host/maintenance/cleanup', cleaner), {
    status: 200, body: { removedFiles: 4, reclaimedBytes: 1024 },
  });
  assert.equal(forced, true);
  assert.equal(await handleMaintenanceRequest('DELETE', '/host/maintenance/cleanup', cleaner), null);
});
