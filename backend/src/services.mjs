const allowedStates = new Set(['pending', 'configuring', 'ready', 'needs_credentials', 'degraded', 'failed']);

export function createServiceRegistry(config) {
  return Object.fromEntries(Object.entries(config).map(([id, value]) => {
    const status = value.status ?? (value.requiresCredential && !value.apiKey ? 'needs_credentials' : 'pending');
    if (!allowedStates.has(status)) throw new Error(`Invalid service status: ${status}`);
    return [id, { id, url: value.url, apiKey: value.apiKey, status }];
  }));
}

export function publicService(service) {
  return { id: service.id, status: service.status, url: service.url };
}
