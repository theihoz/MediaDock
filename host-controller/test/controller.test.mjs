import test from 'node:test';
import assert from 'node:assert/strict';

import { authorize, composeArgs, canStopService, wholeStackCommands } from '../src/controller.mjs';

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

test('protects infrastructure dependencies while api is running', () => {
  assert.deepEqual(canStopService('postgres', new Set(['api'])), {
    allowed: false,
    reason: 'api depends on postgres',
  });
  assert.equal(canStopService('radarr', new Set(['api'])).allowed, true);
});

test('whole stack start applies compose changes only after the user requests start', () => {
  assert.deepEqual(wholeStackCommands('start'), [['compose', 'up', '-d']]);
  assert.deepEqual(wholeStackCommands('stop'), [['compose', 'stop']]);
  assert.deepEqual(wholeStackCommands('restart'), [['compose', 'restart']]);
  assert.throws(() => wholeStackCommands('remove'), /Unsupported action/);
});
