import test from 'node:test';
import assert from 'node:assert/strict';

import { createServiceRegistry, publicService } from '../src/services.mjs';

test('service registry never exposes API keys to desktop clients', () => {
  const registry = createServiceRegistry({
    qbittorrent: { url: 'http://qbittorrent:8080', apiKey: 'super-secret' },
  });

  assert.deepEqual(publicService(registry.qbittorrent), {
    id: 'qbittorrent',
    status: 'pending',
    url: 'http://qbittorrent:8080',
  });
});

test('service registry reports a missing credential as needs_credentials', () => {
  const registry = createServiceRegistry({
    bazarr: { url: 'http://bazarr:6767', requiresCredential: true },
  });

  assert.equal(registry.bazarr.status, 'needs_credentials');
});
