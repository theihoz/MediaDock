import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');

test('bootstrap supports a keep-running first start and writes its completion marker', () => {
  const script = read('scripts/bootstrap.sh');
  assert.match(script, /--keep-running/);
  assert.match(script, /\.bootstrap-complete/);
  assert.doesNotMatch(script, /auto-configure\.ps1[^\n]+\|\| true/);
  assert.match(script, /if \[\[ "\$KEEP_RUNNING" != true \]\]; then[\s\S]+compose[\s\S]+stop/);
  assert.match(script, /\/mnt\/c\/Program Files\/Docker\/Docker\/resources\/bin\/docker\.exe/);
});

test('host controller launcher uses the bundled Node runtime and records only its own PID', () => {
  const script = read('scripts/start-host-controller.ps1');
  assert.match(script, /runtime\\node\.exe/);
  assert.match(script, /controller\.pid/);
  assert.match(script, /WSL_PROJECT_DIR/);
  assert.match(script, /Docker\\Docker\\resources\\bin\\docker\.exe/);
});

test('NSIS creates the requested executables and requires typed destructive confirmation', () => {
  const nsi = read('installer/media-control.nsi');
  assert.match(nsi, /OutFile\s+"\$\{OUTPUT_FILE\}"/);
  assert.match(nsi, /WriteUninstaller\s+"\$INSTDIR\\uninstall\.exe"/);
  assert.match(nsi, /RequestExecutionLevel\s+admin/);
  assert.match(nsi, /XOA TOAN BO/);
  assert.match(nsi, /uninstall-cleanup\.ps1/);
  assert.match(nsi, /Function un\.onInit[\s\S]+IfSilent[\s\S]+Abort/);
});

test('installer build stages an allowlist and rejects private environment files', () => {
  const script = read('scripts/build-installer.ps1');
  assert.match(script, /flutter build windows --release/);
  assert.match(script, /makensis/i);
  assert.match(script, /['"]\/WX['"]/);
  assert.match(script, /node\.exe/);
  assert.match(script, /\.env\.example/);
  assert.match(script, /private environment file/i);
  assert.doesNotMatch(script, /Copy-Item[^\n]+\.env(?:\s|['"]|$)/i);
});

test('local preparation generates private secrets without invoking Docker', () => {
  const script = read('scripts/install-local.ps1');
  assert.match(script, /RandomNumberGenerator/);
  assert.match(script, /\.media-control-root/);
  assert.match(script, /MEDIA_ROOT_DOCKER=\$dockerMediaRoot/);
  assert.doesNotMatch(script, /docker\s+compose/i);
});

test('local preparation writes matching ownership and private environment files', () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'media-install-prepare-'));
  const stack = path.join(temp, 'stack');
  const media = path.join(temp, 'Media');
  fs.mkdirSync(stack);
  fs.copyFileSync(path.join(root, '.env.example'), path.join(stack, '.env.example'));

  execFileSync('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    path.join(root, 'scripts', 'install-local.ps1'),
    '-ProjectDir', stack,
    '-AppDir', path.join(temp, 'app'),
    '-MediaRoot', media,
    '-SkipPreflight', '-SkipFirewall',
  ], { stdio: 'pipe' });

  const env = fs.readFileSync(path.join(stack, '.env'), 'utf8');
  const compose = fs.readFileSync(path.join(stack, '.env.compose'), 'utf8');
  const installId = fs.readFileSync(path.join(stack, '.installation-id'), 'utf8');
  assert.doesNotMatch(env, /replace-with-a-long-random/);
  assert.match(env, /WSL_PROJECT_DIR=\/mnt\/[a-z]\//);
  assert.match(compose, /MEDIA_ROOT_DOCKER=/);
  assert.equal(fs.readFileSync(path.join(media, '.media-control-root'), 'utf8'), installId);
  fs.rmSync(temp, { recursive: true, force: true });
});

test('local preparation upgrades an existing environment without rotating secrets', () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'media-install-upgrade-'));
  const stack = path.join(temp, 'stack');
  const media = path.join(temp, 'Media');
  fs.mkdirSync(stack);
  fs.copyFileSync(path.join(root, '.env.example'), path.join(stack, '.env.example'));
  fs.writeFileSync(path.join(stack, '.env'), 'MEDIA_ROOT=/old\nHOST_CONTROLLER_TOKEN=keep-this-token\n');

  execFileSync('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    path.join(root, 'scripts', 'install-local.ps1'),
    '-ProjectDir', stack,
    '-AppDir', path.join(temp, 'app'),
    '-MediaRoot', media,
    '-SkipPreflight', '-SkipFirewall',
  ], { stdio: 'pipe' });

  const env = fs.readFileSync(path.join(stack, '.env'), 'utf8');
  assert.match(env, /HOST_CONTROLLER_TOKEN=keep-this-token/);
  assert.match(env, /WSL_DISTRO=Ubuntu/);
  assert.match(env, /WSL_PROJECT_DIR=\/mnt\/[a-z]\//);
  assert.match(env, /MEDIA_ROOT=\/mnt\/[a-z]\//);
  fs.rmSync(temp, { recursive: true, force: true });
});

test('uninstall rejects a mismatched marker', () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'media-uninstall-mismatch-'));
  const media = path.join(temp, 'Media');
  fs.mkdirSync(media);
  fs.writeFileSync(path.join(media, '.media-control-root'), 'different-id');
  assert.throws(() => execFileSync('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    path.join(root, 'scripts', 'uninstall-cleanup.ps1'),
    '-MediaRoot', media,
    '-ProjectDir', path.join(temp, 'stack'),
    '-ExpectedInstallationId', 'expected-id',
    '-SkipDocker', '-SkipSystemCleanup',
  ], { stdio: 'pipe' }), /Command failed/);
  fs.rmSync(temp, { recursive: true, force: true });
});

test('uninstall removes the owned tree without following a junction', () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'media-uninstall-owned-'));
  const media = path.join(temp, 'Media');
  const outside = path.join(temp, 'outside');
  fs.mkdirSync(media);
  fs.mkdirSync(outside);
  fs.writeFileSync(path.join(media, '.media-control-root'), 'install-id');
  fs.writeFileSync(path.join(media, 'movie.mkv'), 'owned');
  fs.writeFileSync(path.join(outside, 'keep.txt'), 'keep');
  fs.symlinkSync(outside, path.join(media, 'junction'), 'junction');

  execFileSync('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    path.join(root, 'scripts', 'uninstall-cleanup.ps1'),
    '-MediaRoot', media,
    '-ProjectDir', path.join(temp, 'stack'),
    '-ExpectedInstallationId', 'install-id',
    '-SkipDocker', '-SkipSystemCleanup',
  ], { stdio: 'pipe' });

  assert.equal(fs.existsSync(media), false);
  assert.equal(fs.readFileSync(path.join(outside, 'keep.txt'), 'utf8'), 'keep');
  fs.rmSync(temp, { recursive: true, force: true });
});
