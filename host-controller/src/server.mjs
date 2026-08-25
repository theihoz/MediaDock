import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { existsSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { authorize, canStopService, composeArgs, services, stackStartPlan, wholeStackCommands } from './controller.mjs';
import { handleMaintenanceRequest, MaintenanceCleaner, startMaintenanceSchedule } from './maintenance.mjs';
import { selectLanAddress } from './tv-network.mjs';

const exec = promisify(execFile);
const port = Number(process.env.HOST_CONTROLLER_PORT ?? 3210);
const token = process.env.HOST_CONTROLLER_TOKEN;
const projectDir = process.env.MEDIA_PROJECT_DIR;
const docker = process.env.DOCKER_EXE ?? 'docker';
const envFile = process.env.COMPOSE_ENV_FILE ?? '.env.compose';
const mediaRoot = process.env.MEDIA_ROOT ?? 'D:/Media';
const wslDistro = process.env.WSL_DISTRO ?? 'Ubuntu';
const wslProjectDir = process.env.WSL_PROJECT_DIR;

if (!token || !projectDir) throw new Error('HOST_CONTROLLER_TOKEN and MEDIA_PROJECT_DIR are required');
const maintenance = new MaintenanceCleaner({ mediaRoot });
startMaintenanceSchedule(maintenance);

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

async function compose(args, timeout = 120000) {
  return exec(docker, ['compose', '--env-file', envFile, ...args], { cwd: projectDir, timeout, windowsHide: true });
}

async function startStack() {
  const marker = path.join(mediaRoot, 'config', 'bootstrap', '.bootstrap-complete');
  const plan = stackStartPlan({
    bootstrapComplete: existsSync(marker),
    distro: wslDistro,
    projectDir: wslProjectDir,
  });
  if (plan.kind === 'compose') return compose(plan.args);
  return exec(plan.command, plan.args, { timeout: 30 * 60 * 1000, windowsHide: true });
}

async function listServices() {
  try {
    const { stdout } = await compose(['ps', '--format', 'json'], 15000);
    const rows = stdout.trim().split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
    return rows.map(row => ({
      id: row.Service,
      state: row.State,
      health: row.Health || null,
      status: row.Status,
    }));
  } catch {
    return [];
  }
}

async function handle(req, res) {
  if (!authorize(req.headers, token)) return send(res, 401, { error: 'unauthorized' });
  const url = new URL(req.url, `http://${req.headers.host}`);

  const maintenanceResult = await handleMaintenanceRequest(req.method, url.pathname, maintenance);
  if (maintenanceResult) return send(res, maintenanceResult.status, maintenanceResult.body);

  if (req.method === 'GET' && url.pathname === '/host/status') {
    const current = await listServices();
    const running = current.filter(item => item.state === 'running');
    const state = current.length === 0 ? 'off' : running.length === current.length ? 'ready' : 'degraded';
    return send(res, 200, { state, services: current });
  }
  if (req.method === 'GET' && url.pathname === '/host/services') return send(res, 200, await listServices());
  if (req.method === 'GET' && url.pathname === '/host/tv/status') {
    const lan = selectLanAddress(os.networkInterfaces());
    let reachable = false;
    try {
      const response = await fetch('http://127.0.0.1:8096/System/Info/Public', { signal: AbortSignal.timeout(2000) });
      reachable = response.ok;
    } catch {}
    return send(res, 200, { ...lan, reachable, tcpPort: 8096, discoveryPort: 7359 });
  }

  const whole = url.pathname.match(/^\/host\/(start|stop|restart)$/);
  if (req.method === 'POST' && whole) {
    if (whole[1] === 'start') {
      await startStack();
      return send(res, 202, { state: 'starting' });
    }
    const commands = wholeStackCommands(whole[1]);
    await compose(commands[0].slice(1));
    return send(res, 202, { state: `${whole[1]}ing` });
  }

  const serviceAction = url.pathname.match(/^\/host\/services\/([^/]+)\/(start|stop|restart)$/);
  if (req.method === 'POST' && serviceAction) {
    const [, service, action] = serviceAction;
    if (!services.has(service)) return send(res, 404, { error: 'unknown_service' });
    if (action === 'stop') {
      const running = new Set((await listServices()).filter(item => item.state === 'running').map(item => item.id));
      const guard = canStopService(service, running);
      if (!guard.allowed) return send(res, 409, { error: 'dependency_running', reason: guard.reason });
    }
    await compose(composeArgs(action, service).slice(1));
    return send(res, 202, { id: service, action });
  }

  const logs = url.pathname.match(/^\/host\/services\/([^/]+)\/logs$/);
  if (req.method === 'GET' && logs) {
    if (!services.has(logs[1])) return send(res, 404, { error: 'unknown_service' });
    const { stdout, stderr } = await compose(['logs', '--no-color', '--tail', '200', logs[1]], 15000);
    return send(res, 200, { id: logs[1], logs: `${stdout}${stderr}` });
  }
  return send(res, 404, { error: 'not_found' });
}

http.createServer((req, res) => handle(req, res).catch(error => {
  send(res, 500, { error: 'host_command_failed', message: error.message });
})).listen(port, '127.0.0.1');
