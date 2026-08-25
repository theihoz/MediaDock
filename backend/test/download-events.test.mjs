import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';

import { createDownloadEventsHub } from '../src/download-events.mjs';

class FakeResponse extends EventEmitter {
  constructor({ failHead = false } = {}) {
    super();
    this.failHead = failHead;
    this.failWrites = false;
    this.headers = null;
    this.status = null;
    this.output = '';
  }

  writeHead(status, headers) {
    if (this.failHead) throw new Error('dead response head');
    this.status = status;
    this.headers = headers;
  }

  write(value) {
    if (this.failWrites) throw new Error('dead response write');
    this.output += value;
    return true;
  }
}

function fakeTimers() {
  let nextId = 1;
  const timeouts = new Map();
  const intervals = new Map();
  return {
    timeouts,
    intervals,
    setTimeout(callback, delay) {
      const id = nextId++;
      timeouts.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) { timeouts.delete(id); },
    setInterval(callback, delay) {
      const id = nextId++;
      intervals.set(id, { callback, delay });
      return id;
    },
    clearInterval(id) { intervals.delete(id); },
    runTimeout() {
      const [id, timer] = timeouts.entries().next().value;
      timeouts.delete(id);
      timer.callback();
      return timer.delay;
    },
    heartbeat() { intervals.values().next().value.callback(); },
  };
}

const flush = () => new Promise(resolve => setImmediate(resolve));

test('shares one adaptive poller, deduplicates snapshots, and resets after the final subscriber', async () => {
  const timers = fakeTimers();
  const batches = [
    [{ hash: 'one', progress: 50, state: 'downloading', importStatus: 'downloading' }],
    [{ hash: 'one', progress: 50, state: 'downloading', importStatus: 'downloading' }],
    [{ hash: 'one', progress: 50, state: 'pausedDL', importStatus: 'downloading' }],
  ];
  let loads = 0;
  const hub = createDownloadEventsHub(async () => batches[loads++], { timers, now: () => 1000 });
  const first = new FakeResponse();
  const second = new FakeResponse();

  hub.subscribe(first);
  hub.subscribe(second);
  assert.equal(loads, 1);
  assert.deepEqual([...timers.timeouts.values()].map(timer => timer.delay), [8000], 'only the poll deadline starts before the load settles');
  await flush();
  const late = new FakeResponse();
  hub.subscribe(late);
  assert.equal(loads, 1);
  assert.equal((late.output.match(/event: snapshot/g) ?? []).length, 1, 'late subscribers receive the latest snapshot');
  assert.equal(timers.runTimeout(), 1000);
  await flush();
  assert.equal((first.output.match(/event: snapshot/g) ?? []).length, 1, 'unchanged snapshots are not rebroadcast');
  assert.equal(timers.runTimeout(), 1000);
  await flush();
  assert.equal([...timers.timeouts.values()][0].delay, 5000);
  assert.equal((first.output.match(/event: snapshot/g) ?? []).length, 2);
  assert.equal((second.output.match(/event: snapshot/g) ?? []).length, 2);
  assert.match(first.output, /^retry: 3000\n\nevent: snapshot\ndata: /);
  assert.match(first.output, /"generatedAt":"1970-01-01T00:00:01.000Z"/);
  assert.equal(first.status, 200);
  assert.equal(first.headers['content-type'], 'text/event-stream; charset=utf-8');
  assert.equal(first.headers['cache-control'], 'no-cache');

  timers.heartbeat();
  assert.match(first.output, /: heartbeat\n\n/);
  first.emit('close');
  assert.equal(timers.timeouts.size, 1);
  second.emit('close');
  assert.equal(timers.timeouts.size, 1);
  late.emit('close');
  assert.equal(timers.timeouts.size, 0);
  assert.equal(timers.intervals.size, 0);

  const third = new FakeResponse();
  batches.push([]);
  hub.subscribe(third);
  await flush();
  assert.equal(loads, 4, 'a stopped hub does not reuse stale state');
  third.emit('close');
});

test('emits stable timeout/provider errors and a shared heartbeat', async () => {
  const timers = fakeTimers();
  let loads = 0;
  const hub = createDownloadEventsHub(async () => {
    loads += 1;
    const error = new Error(loads === 1 ? 'timed out' : '<html>secret</html>');
    if (loads === 1) error.code = 'upstream_timeout';
    throw error;
  }, { timers });
  const response = new FakeResponse();

  hub.subscribe(response);
  await flush();
  assert.match(response.output, /event: error\ndata: {"error":"upstream_timeout"}\n\n/);
  assert.equal(timers.runTimeout(), 5000);
  await flush();
  assert.match(response.output, /event: error\ndata: {"error":"provider_unavailable"}\n\n/);
  assert.equal([...timers.intervals.values()][0].delay, 15000);
  timers.heartbeat();
  assert.match(response.output, /: heartbeat\n\n/);
  response.emit('close');
  assert.equal(timers.timeouts.size, 0);
  assert.equal(timers.intervals.size, 0);
});

test('keeps importing and awaiting-import items on the active cadence', async () => {
  const timers = fakeTimers();
  const hub = createDownloadEventsHub(async () => [{
    hash: 'waiting', progress: 100, state: 'pausedUP', importStatus: 'awaiting_import',
  }], { timers });
  const response = new FakeResponse();

  hub.subscribe(response);
  await flush();
  assert.equal([...timers.timeouts.values()][0].delay, 1000);
  response.emit('close');
});

test('aborts a hanging poll and reconnects immediately on a new generation', () => {
  const timers = fakeTimers();
  const signals = [];
  const hub = createDownloadEventsHub(signal => {
    signals.push(signal);
    return new Promise(() => {});
  }, { timers });
  const first = new FakeResponse();
  const second = new FakeResponse();

  hub.subscribe(first);
  assert.equal(signals.length, 1);
  assert.equal(signals[0].aborted, false);
  first.emit('close');
  assert.equal(signals[0].aborted, true);
  hub.subscribe(second);
  assert.equal(signals.length, 2);
  assert.notEqual(signals[1], signals[0]);
  assert.equal(signals[1].aborted, false);
  second.emit('close');
  assert.equal(signals[1].aborted, true);
});

test('aborts a hung shared poll at its deadline and schedules recovery', async () => {
  const timers = fakeTimers();
  const signals = [];
  let loads = 0;
  const hub = createDownloadEventsHub(signal => {
    loads += 1;
    signals.push(signal);
    return loads === 1 ? new Promise(() => {}) : Promise.resolve([]);
  }, { timers, pollTimeoutMs: 8000 });
  const response = new FakeResponse();

  hub.subscribe(response);
  assert.equal([...timers.timeouts.values()][0].delay, 8000);
  assert.equal(timers.runTimeout(), 8000);
  await flush();
  assert.equal(signals[0].aborted, true);
  assert.equal(signals[0].reason.code, 'upstream_timeout');
  assert.match(response.output, /event: error\ndata: {"error":"upstream_timeout"}\n\n/);
  assert.equal(timers.runTimeout(), 5000);
  await flush();
  assert.equal(loads, 2);
  response.emit('close');
  assert.equal(timers.timeouts.size, 0);
  assert.equal(timers.intervals.size, 0);
});

test('isolates write, header, and asynchronous subscriber failures', async () => {
  const timers = fakeTimers();
  let resolveLoad;
  const hub = createDownloadEventsHub(() => new Promise(resolve => { resolveLoad = resolve; }), { timers });
  const badHead = new FakeResponse({ failHead: true });
  assert.doesNotThrow(() => hub.subscribe(badHead));

  const badWrite = new FakeResponse();
  const asyncDead = new FakeResponse();
  const healthy = new FakeResponse();
  hub.subscribe(badWrite);
  hub.subscribe(asyncDead);
  hub.subscribe(healthy);
  badWrite.failWrites = true;
  assert.doesNotThrow(() => asyncDead.emit('error', new Error('socket closed')));
  resolveLoad([]);
  await flush();

  assert.doesNotThrow(() => badHead.emit('error', new Error('late header socket error')));
  assert.doesNotThrow(() => badWrite.emit('error', new Error('late write socket error')));
  assert.equal((healthy.output.match(/event: snapshot/g) ?? []).length, 1);
  assert.equal(timers.timeouts.size, 1);
  healthy.emit('close');
  assert.equal(timers.timeouts.size, 0);
  assert.equal(timers.intervals.size, 0);
});
