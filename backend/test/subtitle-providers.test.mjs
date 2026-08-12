import test from 'node:test';
import assert from 'node:assert/strict';

import {
  filterSubtitleResults,
  mergeSubtitleResults,
  normalizeSubtitle,
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
  const merged = mergeSubtitleResults([[{ provider: 'yifysubtitles', language: 'vi', release: 'Movie.1080p', score: 70 }], [{ provider: 'YIFY Direct', language: 'vi', release: 'movie.1080p', score: 90 }]]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].score, 90);
});

test('uses direct fallback only when enabled and Bazarr has no matches', () => {
  assert.equal(shouldUseDirectFallback({ enabled: true }, []), true);
  assert.equal(shouldUseDirectFallback({ enabled: false }, []), false);
  assert.equal(shouldUseDirectFallback({ enabled: true }, [{ id: 'one' }]), false);
});
