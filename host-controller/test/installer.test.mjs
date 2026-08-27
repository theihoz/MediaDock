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
  assert.match(script, /"\$REPAIR" != true && "\$KEEP_RUNNING" != true[\s\S]+compose[^\n]+stop/);
  assert.match(script, /Setup complete\. Media stack is stopped\. Start it from Media Control or Docker Desktop\./);
  assert.match(script, /\/mnt\/c\/Program Files\/Docker\/Docker\/resources\/bin\/docker\.exe/);
});

test('bootstrap repair reconciles without first-run work and restores stopped state', () => {
  const script = read('scripts/bootstrap.sh');
  assert.match(script, /--repair/);
  assert.match(script, /WAS_RUNNING=false[\s\S]+compose[^\n]+ps --status running --services/);
  assert.match(script, /if \[\[ "\$REPAIR" == true \]\]; then[\s\S]+auto-configure\.ps1[^\n]+-MediaRoot "\$WINDOWS_MEDIA_ROOT"[\s\S]+else[\s\S]+-FirstRun/);
  assert.match(script, /if \[\[ "\$REPAIR" == true && "\$WAS_RUNNING" != true \]\][\s\S]+compose[^\n]+stop/);
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
  assert.equal((env.match(/^MEDIA_ROOT=/gm) ?? []).length, 1);
  assert.equal((env.match(/^MEDIA_ROOT_DOCKER=/gm) ?? []).length, 1);
  assert.equal((compose.match(/^MEDIA_ROOT=/gm) ?? []).length, 1);
  assert.equal((compose.match(/^MEDIA_ROOT_DOCKER=/gm) ?? []).length, 1);
  const dockerMedia = media.replaceAll('\\', '/');
  const envValues = Object.fromEntries(env.split(/\r?\n/).filter(line => line.includes('=')).map(line => line.split(/=(.*)/s).slice(0, 2)));
  const composeValues = Object.fromEntries(compose.split(/\r?\n/).filter(line => line.includes('=')).map(line => line.split(/=(.*)/s).slice(0, 2)));
  assert.equal(envValues.MEDIA_ROOT_DOCKER, dockerMedia);
  assert.equal(composeValues.MEDIA_ROOT, dockerMedia);
  assert.equal(composeValues.MEDIA_ROOT_DOCKER, dockerMedia);
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
  assert.equal((env.match(/^MEDIA_ROOT=/gm) ?? []).length, 1);
  assert.equal((env.match(/^MEDIA_ROOT_DOCKER=/gm) ?? []).length, 1);
  fs.rmSync(temp, { recursive: true, force: true });
});

test('local preparation preserves a custom compose media root when an update omits MediaRoot', () => {
  const script = read('scripts/install-local.ps1');
  const parameterBlock = script.slice(0, script.indexOf('$ErrorActionPreference'));
  assert.doesNotMatch(parameterBlock, /\[string\]\$MediaRoot\s*=\s*'D:\\Media'/);
  const composeLookup = script.indexOf("Join-Path $ProjectDir '.env.compose'");
  const registryLookup = script.indexOf("HKLM:\\Software\\MediaControl");
  const defaultLookup = script.indexOf("$MediaRoot = 'D:\\Media'");
  assert.ok(composeLookup >= 0 && registryLookup > composeLookup && defaultLookup > registryLookup);

  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'media-install-custom-update-'));
  try {
    const stack = path.join(temp, 'stack');
    const media = path.join(temp, 'Custom Media');
    fs.mkdirSync(stack);
    fs.copyFileSync(path.join(root, '.env.example'), path.join(stack, '.env.example'));
    const common = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'scripts', 'install-local.ps1'), '-ProjectDir', stack, '-AppDir', path.join(temp, 'app'), '-SkipPreflight', '-SkipFirewall'];
    execFileSync('powershell.exe', [...common, '-MediaRoot', media], { stdio: 'pipe' });
    execFileSync('powershell.exe', common, { stdio: 'pipe' });

    const dockerMedia = media.replaceAll('\\', '/');
    const compose = fs.readFileSync(path.join(stack, '.env.compose'), 'utf8');
    assert.match(compose, new RegExp(`^MEDIA_ROOT=${dockerMedia.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'm'));
    assert.match(compose, new RegExp(`^MEDIA_ROOT_DOCKER=${dockerMedia.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'm'));
    assert.equal(fs.existsSync(path.join(media, '.media-control-root')), true);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
});

test('installer update repairs providers and uninstall reuses the registered media root', () => {
  const install = read('scripts/install-local.ps1');
  const nsi = read('installer/media-control.nsi');
  assert.match(install, /\[switch\]\$RepairProviders/);
  assert.match(install, /Join-Path \$ProjectDir 'scripts\\bootstrap\.sh'[\s\S]+--repair/);
  assert.match(nsi, /ReadRegStr \$MediaRoot HKLM "Software\\MediaControl" "MediaRoot"/);
  assert.match(nsi, /-MediaRoot "\$MediaRoot"/);
  assert.match(nsi, /\$IsUpdate[\s\S]+-RepairProviders/);
  assert.match(nsi, /WriteRegStr HKLM "Software\\MediaControl" "MediaRoot" "\$MediaRoot"/);
  assert.match(nsi, /Function un\.onInit[\s\S]+ReadRegStr \$MediaRoot HKLM "Software\\MediaControl" "MediaRoot"/);
  assert.match(nsi, /uninstall-cleanup\.ps1" -MediaRoot "\$MediaRoot"/);
});

test('manual-start checks live in Node tests and installers never register automatic startup', () => {
  const scriptsDir = path.join(root, 'scripts');
  const forbidden = /Register-ScheduledTask|schtasks(?:\.exe)?\s+\/create|CurrentVersion\\Run|Startup\\|New-Service/;
  const installers = fs.readdirSync(scriptsDir)
    .filter(name => name.endsWith('.ps1') && name !== 'test-manual-start.ps1')
    .map(name => fs.readFileSync(path.join(scriptsDir, name), 'utf8'));
  assert.doesNotMatch(installers.join('\n'), forbidden);
  assert.equal(fs.existsSync(path.join(scriptsDir, 'test-manual-start.ps1')), false);

  const compose = read('docker-compose.yml');
  assert.match(compose, /x-common: &common[\s\S]+restart: "no"/);
  assert.match(compose, /api:\s*\n\s+build: \.\/backend\s*\n\s+restart: "no"/);
  assert.equal((compose.match(/restart: "no"/g) ?? []).length, 2);
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

test('release version has one pubspec source and reaches NSIS', () => {
  const pubspec = read('flutter_app/pubspec.yaml');
  const build = read('scripts/build-installer.ps1');
  const nsi = read('installer/media-control.nsi');
  assert.match(pubspec, /^version: 0\.2\.0\+2$/m);
  assert.match(build, /flutter_app[\\/]pubspec\.yaml/);
  assert.ok(build.includes('(?<version>\\d+\\.\\d+\\.\\d+)'));
  assert.match(build, /"\/DAPP_VERSION=\$appVersion"/);
  assert.doesNotMatch(build, /0\.2\.0/);
  assert.match(nsi, /!ifndef APP_VERSION[\s\S]+!error "APP_VERSION is required"/);
  assert.match(nsi, /"DisplayVersion" "\$\{APP_VERSION\}"/);
  assert.match(nsi, /"Publisher" "theihoz"/);
  assert.doesNotMatch(nsi, /0\.2\.0/);
  assert.doesNotMatch(nsi, /DisplayVersion" "0\.1\.0"/);
});

test('README has the requested English-only structure and release links', () => {
  const readme = read('README.md');
  assert.deepEqual(readme.match(/^#{1,2} .+$/gm), [
    '# Media Control',
    '## Installation Instructions',
    '## Usage',
    '## Examples / Demos',
    '## License',
  ]);
  for (const target of ['docs/guide.en.md', 'docs/guide.vi.md', 'CHANGELOG.md', 'LICENSE']) {
    assert.match(readme, new RegExp(`\\(${target.replace('.', '\\.') }\\)`));
    assert.equal(fs.existsSync(path.join(root, target)), true);
  }
  assert.doesNotMatch(readme, /Autobrr|PostgreSQL|Redis/);
});

test('English and Vietnamese guides have equivalent ordered sections', () => {
  const english = read('docs/guide.en.md');
  const vietnamese = read('docs/guide.vi.md');
  const directRepair = String.raw`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\auto-configure.ps1 -MediaRoot 'D:\Media'`;
  assert.deepEqual(english.match(/^## .+$/gm), [
    '## Installation',
    '## Workspaces',
    '## Workflows',
    '## Providers',
    '## Configuration',
    '## Docker',
    '## Troubleshooting',
    '## Repair',
    '## Safe uninstall',
  ]);
  assert.deepEqual(vietnamese.match(/^## .+$/gm), [
    '## Cài đặt',
    '## Không gian làm việc',
    '## Quy trình sử dụng',
    '## Nhà cung cấp',
    '## Cấu hình',
    '## Docker',
    '## Khắc phục sự cố',
    '## Sửa chữa',
    '## Gỡ cài đặt an toàn',
  ]);
  for (const guide of [english, vietnamese]) {
    assert.ok(guide.replaceAll('\r\n', '\n').includes(`\`\`\`powershell\n${directRepair}\n\`\`\``));
    assert.match(guide, /-FirstRun/);
    assert.match(guide, /MEDIA_ROOT/);
    assert.match(guide, /MEDIA_ROOT_DOCKER/);
    assert.match(guide, /Seerr/);
    assert.match(guide, /YTS/);
    assert.match(guide, /YIFY Direct/);
    assert.match(guide, /OpenSubtitles/);
    assert.match(guide, /down -v/);
    assert.match(guide, /volume rm/);
  }
  assert.match(english, /replaces placeholders with generated secrets on a new installation and preserves them on update/);
  assert.match(vietnamese, /sinh secret thay placeholder ở lần cài mới và giữ nguyên khi cập nhật/);
});

test('release metadata is Media Control 0.2.0 by theihoz', () => {
  const license = read('LICENSE');
  const changelog = read('CHANGELOG.md');
  const runner = read('flutter_app/windows/runner/Runner.rc');
  assert.match(license, /^MIT License$/m);
  assert.match(license, /Copyright \(c\) 2026 theihoz/);
  assert.match(changelog, /^## \[0\.2\.0\] - 2026-08-25$/m);
  assert.match(runner, /VALUE "CompanyName", "theihoz"/);
  assert.match(runner, /VALUE "FileDescription", "Media Control"/);
  assert.match(runner, /VALUE "InternalName", "media_control"/);
  assert.match(runner, /VALUE "LegalCopyright", "Copyright \(C\) 2026 theihoz/);
  assert.match(runner, /VALUE "OriginalFilename", "media_control\.exe"/);
  assert.match(runner, /VALUE "ProductName", "Media Control"/);
  assert.match(runner, /VALUE "ProductVersion", VERSION_AS_STRING/);
});

test('release removes stale planning docs and ignores editor state', () => {
  const stale = [
    'flutter_app/README.md',
    'docs/superpowers/plans/2026-08-12-yify-subtitle-fallback.md',
    'docs/superpowers/plans/2026-08-13-manual-start-cold-boot-trending.md',
    'docs/superpowers/plans/2026-08-13-multi-provider-subtitle-results.md',
    'docs/superpowers/plans/2026-08-13-nyaa-hybrid-source.md',
    'docs/superpowers/plans/2026-08-13-parallel-download-sources.md',
    'docs/superpowers/plans/2026-08-13-season-vietsub-auto-search.md',
    'docs/superpowers/plans/2026-08-13-tv-show-trending.md',
    'docs/superpowers/plans/2026-08-13-unified-media-search.md',
    'docs/superpowers/plans/2026-08-13-vietsub-series-season.md',
    'docs/superpowers/plans/2026-08-13-yts-official-tv-download.md',
    'docs/superpowers/specs/2026-08-12-yify-subtitle-fallback-design.md',
    'docs/superpowers/specs/2026-08-13-manual-start-cold-boot-trending-design.md',
    'docs/superpowers/specs/2026-08-13-multi-provider-subtitle-results-design.md',
    'docs/superpowers/specs/2026-08-13-nyaa-hybrid-source-design.md',
    'docs/superpowers/specs/2026-08-13-season-vietsub-auto-search-design.md',
    'docs/superpowers/specs/2026-08-13-tv-show-trending-design.md',
    'docs/superpowers/specs/2026-08-13-unified-media-search-design.md',
    'docs/superpowers/specs/2026-08-13-vietsub-series-season-design.md',
    'docs/superpowers/specs/2026-08-13-yts-official-tv-download-design.md',
  ];
  assert.equal(stale.length, 20);
  for (const relative of stale) assert.equal(fs.existsSync(path.join(root, relative)), false, relative);
  assert.equal(fs.existsSync(path.join(root, 'README.vi.md')), false);
  const ignore = read('.gitignore');
  assert.match(ignore, /^\.idea\/$/m);
  assert.match(ignore, /^\.vscode\/$/m);
});
