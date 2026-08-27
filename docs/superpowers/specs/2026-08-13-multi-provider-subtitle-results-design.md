# Multi-provider Subtitle Results Design

## Goal

When `Tất cả provider` is selected, show usable results from every enabled subtitle provider instead of collapsing matching releases into one provider or hiding a provider that only has an English fallback.

## Backend behavior

- Search Bazarr once so Gestdown, YIFY Subtitles, and OpenSubtitles.com continue running concurrently inside Bazarr.
- Preserve provider identity while deduplicating. Two results with the same language and release but different providers remain separate.
- Deduplicate only within the same provider, language, release, format, and hearing-impaired variant, retaining the highest score.
- For `provider=all`, return Vietnamese results first and English results second.
- For an explicitly selected provider, keep the requested language filter and return only that provider.
- Do not expose raw provider URLs, Bazarr API keys, credentials, or unsigned selection data.
- Add `fallback: true` to English entries returned while the requested language is Vietnamese.

## Flutter behavior

- Group result cards by provider with a visible provider heading and result count.
- Keep Vietnamese entries first within each group.
- Show `English fallback` on fallback entries.
- Show enabled providers with no result as `Không có kết quả` so users can distinguish an empty provider from a provider that was never queried.
- Keep download selection per result and retain provider/language/score/release details.
- Selecting one provider keeps the existing single-provider list behavior.

## Season automation

- Automatic season search remains Vietnamese-only.
- English fallback results are not automatically downloaded and do not count as Vietsub coverage.

## Tests

- Same release from Gestdown and OpenSubtitles remains as two results.
- Duplicate rows within one provider collapse to the highest score.
- `provider=all&language=vi` includes Vietnamese plus English fallback rows.
- Explicit provider selection remains language-strict.
- Flutter renders all enabled provider groups, result counts, English fallback labels, and empty-provider states.
- Full backend/controller and Flutter suites remain green.
