import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('bootstrap disables Internet Archive and leaves YTS enabled', () => {
  const script = fs.readFileSync(new URL('../../scripts/auto-configure.ps1', import.meta.url), 'utf8');
  assert.match(script, /Where-Object name -eq 'Internet Archive'[\s\S]+Set-Property \$archive enable \$false/);
  assert.match(script, /Where-Object name -eq 'YTS'[\s\S]+Set-Property \$yts enable \$true/);
});

test('compose bounds Docker stdout logs for every service group', () => {
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  assert.match(compose, /x-logging: &logging[\s\S]+driver: local[\s\S]+max-size: "10m"[\s\S]+max-file: "2"/);
  assert.equal((compose.match(/logging: \*logging/g) ?? []).length, 4);
});
