import test from 'node:test';
import assert from 'node:assert/strict';

import { createSubtitleToken, verifySubtitleToken } from '../src/subtitle-token.mjs';

test('round-trips a signed token within five minutes', () => {
  const token = createSubtitleToken({ provider: 'yify', subtitleId: '42' }, 'secret', 1000);
  assert.deepEqual(verifySubtitleToken(token, 'secret', 1299), { provider: 'yify', subtitleId: '42' });
});

test('rejects token tampering and expiry', () => {
  const token = createSubtitleToken({ provider: 'yify', subtitleId: '42' }, 'secret', 1000);
  assert.throws(() => verifySubtitleToken(`${token}x`, 'secret', 1001), /invalid token/);
  assert.throws(() => verifySubtitleToken(token, 'secret', 1301), /expired token/);
});

test('does not expose provider URLs as readable token text', () => {
  const token = createSubtitleToken({ provider: 'yify', subtitleId: '42', url: 'https://private.example/file' }, 'secret', 1000);
  assert.equal(token.includes('private.example'), false);
});
