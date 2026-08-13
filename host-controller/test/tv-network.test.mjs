import test from 'node:test';
import assert from 'node:assert/strict';

import { selectLanAddress } from '../src/tv-network.mjs';

test('selects a private IPv4 address for the Samsung TV URL', () => {
  const address = selectLanAddress({
    Loopback: [{ address: '127.0.0.1', family: 'IPv4', internal: true }],
    Ethernet: [{ address: '192.168.1.42', family: 'IPv4', internal: false }],
    Docker: [{ address: '172.20.0.1', family: 'IPv4', internal: false }],
  });
  assert.deepEqual(address, { address: '192.168.1.42', url: 'http://192.168.1.42:8096' });
});

test('does not advertise public or loopback addresses', () => {
  assert.equal(selectLanAddress({ Ethernet: [{ address: '8.8.8.8', family: 'IPv4', internal: false }] }), null);
});
