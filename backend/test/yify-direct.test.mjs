import test from 'node:test';
import assert from 'node:assert/strict';

import { YifyDirectProvider } from '../src/yify-direct.mjs';

test('disabled direct provider never performs a network request', async () => {
  let called = false;
  const provider = new YifyDirectProvider({ enabled: false, fetchImpl: async () => { called = true; } });
  await assert.rejects(() => provider.search({ imdbId: 'tt1', title: 'Movie', year: 2020 }, 'vi'), /provider_disabled/);
  assert.equal(called, false);
});

test('parses only matching public subtitle links', async () => {
  const html = `<tr data-id="42"><td><span class="label label-success">91</span></td><td><span class="sub-lang">Vietnamese</span></td><td><a href="/subtitles/movie-2020-vietnamese-yify-42"><span>subtitle</span> Movie.2020.1080p</a></td><td><span class="hi-subtitle"></span></td></tr>
    <tr data-id="99"><td><span class="label">1</span></td><td><span class="sub-lang">English</span></td><td><a href="/subtitles/wrong">Wrong</a></td></tr>`;
  const provider = new YifyDirectProvider({ enabled: true, baseUrl: 'https://subs.example', fetchImpl: async () => new Response(html) });
  const results = await provider.search({ imdbId: 'tt1', title: 'Movie', year: 2020 }, 'vi');
  assert.equal(results.length, 1);
  assert.equal(results[0].subtitleId, '/subtitles/movie-2020-vietnamese-yify-42');
  assert.equal(results[0].score, 91);
});

test('reports browser challenges as provider unavailable', async () => {
  const provider = new YifyDirectProvider({ enabled: true, baseUrl: 'https://subs.example', fetchImpl: async () => new Response('Checking your browser Cloudflare captcha') });
  await assert.rejects(() => provider.search({ imdbId: 'tt1' }, 'vi'), /provider_unavailable/);
});

test('treats a missing IMDb page as no subtitle results', async () => {
  const provider = new YifyDirectProvider({ enabled: true, baseUrl: 'https://subs.example', fetchImpl: async () => new Response('Not found', { status: 404 }) });
  assert.deepEqual(await provider.search({ imdbId: 'tt-missing' }, 'vi'), []);
});

test('downloads only bounded subtitle payloads from the configured origin', async () => {
  const provider = new YifyDirectProvider({ enabled: true, baseUrl: 'https://subs.example', fetchImpl: async () => new Response('1\n00:00:00,000 --> 00:00:01,000\nHello', { headers: { 'content-type': 'application/x-subrip' } }) });
  const result = await provider.download('/subtitle/42.srt');
  assert.equal(result.format, 'srt');
  assert.match(result.buffer.toString(), /Hello/);
  await assert.rejects(() => provider.download('https://evil.example/file.srt'), /invalid_subtitle_url/);
});
