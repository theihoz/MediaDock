import test from 'node:test';
import assert from 'node:assert/strict';

import {
  filterSubtitleResults,
  mergeSubtitleResults,
  normalizeSubtitle,
  selectSubtitleResults,
  shouldUseDirectFallback,
} from '../src/subtitle-providers.mjs';

test('normalizes provider output without exposing a raw download URL', () => {
  const item = normalizeSubtitle({
    provider: 'yifysubtitles', language: 'vi', release: 'Movie.1080p',
    score: 92, hearing_impaired: true, format: 'srt', url: 'https://secret.example/file',
  }, 'bazarr');
  assert.deepEqual(item, {
    id: 'bazarr:yifysubtitles:vi:Movie.1080p', provider: 'yifysubtitles', source: 'bazarr',
    language: 'vi', release: 'Movie.1080p', score: 92, hearingImpaired: true,
    format: 'srt', downloadToken: null,
  });
  assert.equal('url' in item, false);
});

test('filters by language and provider', () => {
  const items = [
    { language: 'vi', provider: 'gestdown' },
    { language: 'vi', provider: 'yifysubtitles' },
    { language: 'en', provider: 'yifysubtitles' },
  ];
  assert.deepEqual(filterSubtitleResults(items, 'vi', 'yifysubtitles'), [items[1]]);
});

test('merges duplicate releases and keeps the highest score', () => {
  const merged = mergeSubtitleResults([[
    { provider: 'opensubtitlescom', language: 'vi', release: 'Movie.1080p', format: 'srt', score: 70 },
    { provider: 'opensubtitlescom', language: 'vi', release: 'movie.1080p', format: 'srt', score: 90 },
  ], [
    { provider: 'gestdown', language: 'vi', release: 'movie.1080p', format: 'srt', score: 80 },
  ]]);
  assert.equal(merged.length, 2);
  assert.deepEqual(merged.map(item => [item.provider, item.score]), [
    ['opensubtitlescom', 90],
    ['gestdown', 80],
  ]);
});

test('all providers includes Vietnamese first and marks English fallback', () => {
  const items = [
    { provider: 'gestdown', language: 'en', release: 'Episode.1080p', score: 88 },
    { provider: 'opensubtitlescom', language: 'vi', release: 'Episode.1080p', score: 75 },
    { provider: 'opensubtitlescom', language: 'en', release: 'Episode.720p', score: 90 },
  ];
  const selected = selectSubtitleResults(items, 'vi', 'all');
  assert.deepEqual(selected.map(item => [item.provider, item.language, item.fallback]), [
    ['opensubtitlescom', 'vi', false],
    ['gestdown', 'en', true],
    ['opensubtitlescom', 'en', true],
  ]);
  assert.deepEqual(selectSubtitleResults(items, 'vi', 'gestdown'), []);
});

test('uses direct fallback only when enabled and Bazarr has no matches', () => {
  assert.equal(shouldUseDirectFallback({ enabled: true }, []), true);
  assert.equal(shouldUseDirectFallback({ enabled: false }, []), false);
  assert.equal(shouldUseDirectFallback({ enabled: true }, [{ id: 'one' }]), false);
});
