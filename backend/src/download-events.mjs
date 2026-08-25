const activeStates = new Set(['active', 'downloading', 'importing']);
const idleIncompleteStates = new Set(['pausedDL', 'stoppedDL', 'error', 'missingFiles']);

function event(name, value) {
  return `event: ${name}\ndata: ${JSON.stringify(value)}\n\n`;
}

export function createDownloadEventsHub(load, { timers = globalThis, now = Date.now, pollTimeoutMs = 8000 } = {}) {
  const subscribers = new Map();
  let pollTimer;
  let heartbeatTimer;
  let activeController;
  let activeDeadlineTimer;
  let latest;
  let signature;
  let generation = 0;

  const stop = () => {
    generation += 1;
    if (pollTimer !== undefined) timers.clearTimeout(pollTimer);
    if (heartbeatTimer !== undefined) timers.clearInterval(heartbeatTimer);
    if (activeDeadlineTimer !== undefined) timers.clearTimeout(activeDeadlineTimer);
    activeController?.abort();
    pollTimer = undefined;
    heartbeatTimer = undefined;
    activeController = undefined;
    activeDeadlineTimer = undefined;
    latest = undefined;
    signature = undefined;
  };
  const remove = response => {
    const cleanup = subscribers.get(response);
    if (!cleanup) return;
    subscribers.delete(response);
    if (!subscribers.size) stop();
  };
  const write = (response, value) => {
    try {
      response.write(value);
      return true;
    } catch {
      remove(response);
      return false;
    }
  };
  const broadcast = value => [...subscribers.keys()].forEach(response => write(response, value));
  const schedule = (delay, currentGeneration) => {
    if (!subscribers.size || currentGeneration !== generation) return;
    pollTimer = timers.setTimeout(() => {
      pollTimer = undefined;
      void poll(currentGeneration);
    }, delay);
  };
  const poll = async currentGeneration => {
    const controller = new AbortController();
    const timeoutError = new Error('upstream_timeout');
    timeoutError.code = 'upstream_timeout';
    let deadlineTimer;
    let onAbort;
    const aborted = new Promise((_, reject) => {
      onAbort = () => reject(controller.signal.reason);
      controller.signal.addEventListener('abort', onAbort, { once: true });
    });
    activeController = controller;
    deadlineTimer = timers.setTimeout(() => controller.abort(timeoutError), pollTimeoutMs);
    activeDeadlineTimer = deadlineTimer;
    try {
      try {
        const items = await Promise.race([load(controller.signal), aborted]);
        if (!subscribers.size || currentGeneration !== generation) return;
        const nextSignature = JSON.stringify(items);
        if (nextSignature !== signature) {
          signature = nextSignature;
          latest = { items, generatedAt: new Date(now()).toISOString() };
          broadcast(event('snapshot', latest));
        }
        const active = items.some(item => {
          if (item.importStatus === 'awaiting_import' || activeStates.has(item.state)) return true;
          if (Number(item.progress) < 100) return !idleIncompleteStates.has(item.state);
          return false;
        });
        schedule(active ? 1000 : 5000, currentGeneration);
      } catch (error) {
        if (!subscribers.size || currentGeneration !== generation) return;
        const code = error?.code === 'upstream_timeout' || error?.name === 'AbortError' ? 'upstream_timeout' : 'provider_unavailable';
        broadcast(event('error', { error: code }));
        schedule(5000, currentGeneration);
      }
    } finally {
      controller.signal.removeEventListener('abort', onAbort);
      timers.clearTimeout(deadlineTimer);
      if (activeDeadlineTimer === deadlineTimer) activeDeadlineTimer = undefined;
      if (activeController === controller) activeController = undefined;
    }
  };

  return {
    subscribe(response) {
      const cleanup = () => remove(response);
      subscribers.set(response, cleanup);
      response.once('close', cleanup);
      response.once('error', cleanup);
      try {
        response.writeHead(200, {
          'content-type': 'text/event-stream; charset=utf-8',
          'cache-control': 'no-cache',
          connection: 'keep-alive',
        });
      } catch {
        remove(response);
        return;
      }
      if (!write(response, 'retry: 3000\n\n')) return;
      if (latest && !write(response, event('snapshot', latest))) return;
      if (subscribers.size === 1) {
        const currentGeneration = generation;
        heartbeatTimer = timers.setInterval(() => broadcast(': heartbeat\n\n'), 15000);
        void poll(currentGeneration);
      }
    },
  };
}
