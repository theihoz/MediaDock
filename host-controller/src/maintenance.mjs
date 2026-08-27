import fs from 'node:fs/promises';
import path from 'node:path';

const hourMs = 60 * 60 * 1000;
const dayMs = 24 * hourMs;
const logRoots = [
  ['config', 'radarr', 'logs'],
  ['config', 'sonarr', 'logs'],
  ['config', 'prowlarr', 'logs'],
  ['config', 'bazarr', 'log'],
  ['config', 'bazarr', 'logs'],
  ['config', 'jellyfin', 'log'],
  ['config', 'seerr', 'logs'],
  ['config', 'qbittorrent', 'qBittorrent', 'logs'],
];
const preservedCache = ['cache/trending.json', 'cache/trending-tv.json'];

export class MaintenanceCleaner {
  constructor({ mediaRoot, retentionMs = dayMs, now = () => new Date() }) {
    if (!mediaRoot) throw new Error('MEDIA_ROOT is required for maintenance');
    this.mediaRoot = path.resolve(mediaRoot);
    this.retentionMs = retentionMs;
    this.now = now;
    this.lastResult = null;
    this.nextRunAt = null;
  }

  status() {
    return {
      lastRunAt: this.lastResult?.lastRunAt ?? null,
      nextRunAt: this.nextRunAt,
      removedFiles: this.lastResult?.removedFiles ?? 0,
      reclaimedBytes: this.lastResult?.reclaimedBytes ?? 0,
      failed: this.lastResult?.failed ?? [],
      preserved: preservedCache,
    };
  }

  async cleanup({ force = false } = {}) {
    const now = this.now();
    const result = { lastRunAt: now.toISOString(), removedFiles: 0, reclaimedBytes: 0, failed: [], preserved: preservedCache };
    const roots = [path.join(this.mediaRoot, 'cache'), ...logRoots.map(parts => path.join(this.mediaRoot, ...parts))];
    for (const root of roots) await this.cleanDirectory(root, { force, now, result });
    this.lastResult = result;
    this.nextRunAt = new Date(now.getTime() + hourMs).toISOString();
    return { ...result, nextRunAt: this.nextRunAt };
  }

  async cleanDirectory(directory, context) {
    let entries;
    try { entries = await fs.readdir(directory, { withFileTypes: true }); }
    catch (error) {
      if (error.code !== 'ENOENT') context.result.failed.push({ path: path.relative(this.mediaRoot, directory), reason: error.code ?? 'read_failed' });
      return;
    }
    for (const entry of entries) {
      const target = path.resolve(directory, entry.name);
      const relative = path.relative(this.mediaRoot, target);
      if (relative.startsWith('..') || path.isAbsolute(relative) || entry.isSymbolicLink()) continue;
      if (preservedCache.includes(relative.replaceAll('\\', '/'))) continue;
      if (entry.isDirectory()) {
        await this.cleanDirectory(target, context);
        continue;
      }
      if (!entry.isFile()) continue;
      try {
        const stat = await fs.stat(target);
        if (!context.force && context.now.getTime() - stat.mtimeMs <= this.retentionMs) continue;
        await fs.unlink(target);
        context.result.removedFiles += 1;
        context.result.reclaimedBytes += stat.size;
      } catch (error) {
        context.result.failed.push({ path: relative, reason: error.code ?? 'delete_failed' });
      }
    }
  }
}

export function startMaintenanceSchedule(cleaner, { schedule = setInterval } = {}) {
  Promise.resolve(cleaner.cleanup({ force: false })).catch(() => {});
  cleaner.nextRunAt = new Date(Date.now() + hourMs).toISOString();
  const timer = schedule(() => cleaner.cleanup({ force: false }).catch(() => {}), hourMs);
  timer.unref?.();
  return timer;
}

export async function handleMaintenanceRequest(method, pathname, cleaner) {
  if (method === 'GET' && pathname === '/host/maintenance/status') return { status: 200, body: cleaner.status() };
  if (method === 'POST' && pathname === '/host/maintenance/cleanup') return { status: 200, body: await cleaner.cleanup({ force: true }) };
  return null;
}
