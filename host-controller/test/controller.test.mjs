import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { authorize, composeArgs, services, stackStartPlan, wholeStackCommands } from '../src/controller.mjs';

test('rejects requests without the local bearer token', () => {
  assert.equal(authorize({}, 'local-token'), false);
  assert.equal(authorize({ authorization: 'Bearer local-token' }, 'local-token'), true);
});

test('builds compose commands only for known actions and services', () => {
  assert.deepEqual(composeArgs('start', 'radarr'), ['compose', 'start', 'radarr']);
  assert.deepEqual(composeArgs('restart'), ['compose', 'restart']);
  assert.throws(() => composeArgs('remove', 'radarr'), /Unsupported action/);
  assert.throws(() => composeArgs('stop', 'unknown'), /Unknown service/);
});

test('exposes only services in the current Compose stack', () => {
  assert.deepEqual([...services].sort(), [
    'api', 'bazarr', 'flaresolverr', 'jellyfin', 'prowlarr',
    'qbittorrent', 'radarr', 'seerr', 'sonarr',
  ].sort());
  for (const retired of ['autobrr', 'postgres', 'redis']) {
    assert.equal(services.has(retired), false);
    assert.throws(() => composeArgs('stop', retired), /Unknown service/);
  }
});

test('host command failures expose only a stable error code', async () => {
  const source = await readFile(new URL('../src/server.mjs', import.meta.url), 'utf8');
  assert.match(source, /host_command_failed/);
  assert.doesNotMatch(source, /host_command_failed'\s*,\s*message:/);
});

test('whole stack start applies compose changes only after the user requests start', () => {
  assert.deepEqual(wholeStackCommands('start'), [['compose', 'up', '-d', '--remove-orphans']]);
  assert.deepEqual(wholeStackCommands('stop'), [['compose', 'stop']]);
  assert.deepEqual(wholeStackCommands('restart'), [['compose', 'restart']]);
  assert.throws(() => wholeStackCommands('remove'), /Unsupported action/);
});

test('first start bootstraps in Ubuntu and later starts use Compose directly', () => {
  assert.deepEqual(stackStartPlan({
    bootstrapComplete: false,
    distro: 'Ubuntu',
    projectDir: '/mnt/c/ProgramData/MediaControl/stack',
  }), {
    kind: 'bootstrap',
    command: 'wsl.exe',
    args: [
      '-d', 'Ubuntu', '--', 'bash',
      '/mnt/c/ProgramData/MediaControl/stack/scripts/bootstrap.sh',
      '--keep-running',
    ],
  });
  assert.deepEqual(stackStartPlan({ bootstrapComplete: true }), {
    kind: 'compose',
    args: ['up', '-d', '--remove-orphans'],
  });
  assert.throws(() => stackStartPlan({ bootstrapComplete: false }), /WSL bootstrap settings/);
});
