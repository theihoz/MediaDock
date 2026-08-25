export const services = new Set([
  'api', 'autobrr', 'bazarr', 'flaresolverr', 'jellyfin', 'postgres',
  'prowlarr', 'qbittorrent', 'radarr', 'redis', 'seerr', 'sonarr',
]);

const actions = new Set(['start', 'stop', 'restart']);

export function authorize(headers, token) {
  return Boolean(token) && headers.authorization === `Bearer ${token}`;
}

export function composeArgs(action, service) {
  if (!actions.has(action)) throw new Error(`Unsupported action: ${action}`);
  if (service && !services.has(service)) throw new Error(`Unknown service: ${service}`);
  return ['compose', action, ...(service ? [service] : [])];
}

export function wholeStackCommands(action) {
  if (action === 'start') return [['compose', 'up', '-d']];
  if (action === 'stop') return [['compose', 'stop']];
  if (action === 'restart') return [['compose', 'restart']];
  throw new Error(`Unsupported action: ${action}`);
}

export function stackStartPlan({ bootstrapComplete, distro, projectDir }) {
  if (bootstrapComplete) return { kind: 'compose', args: ['up', '-d'] };
  if (!distro || !projectDir) throw new Error('WSL bootstrap settings are missing');
  return {
    kind: 'bootstrap',
    command: 'wsl.exe',
    args: [
      '-d', distro, '--', 'bash',
      `${projectDir}/scripts/bootstrap.sh`, '--keep-running',
    ],
  };
}

export function canStopService(service, running) {
  if (service === 'postgres' && running.has('api')) return { allowed: false, reason: 'api depends on postgres' };
  if (service === 'redis' && running.has('api')) return { allowed: false, reason: 'api depends on redis' };
  return { allowed: true };
}
