# TV Show Trending Design

## Goal

Show a populated `Đang thịnh hành` section immediately when the TV Show tab opens, while preserving text search and the YTS Official-only TV download flow.

## Source and fallback

The backend calls YTS Official's public catalogue endpoint with TV mode:

1. `GET /?api=trending&mode=tv&page=1&sort=popularity.desc`
2. On an unavailable or empty response, `GET /?api=popular&mode=tv&page=1&sort=popularity.desc`
3. On an unavailable or empty fallback response, read the last-good local cache.

Each source response is normalized to the existing discovery card model: `mediaType: 'series'`, `tvdbId` when supplied, provider item ID, title, year, overview, poster, rating, and `inLibrary`. The backend returns `{ items, stale, source }`, where `source` is `yts_official`, `popular`, `cache`, or `unavailable`.

The last-good list is stored at `/data/cache/trending-tv.json`. It is protected by host-controller maintenance exactly like the movie trending cache. A live successful response atomically replaces the cache. Requests are limited to 15 seconds and concurrent requests are coalesced.

## Flutter behavior

When TV Show is selected and the search box is empty, Flutter loads `/v1/series/trending` and renders a `Đang thịnh hành` grid. It shows a small source chip:

- `Đang thịnh hành` for the primary YTS Official feed.
- `Phổ biến trên YTS Official` for the popular fallback.
- `Dữ liệu gần nhất` for cache.

Search begins once text is entered and remains unchanged. Clearing the query returns to the trending grid. A concise retry state appears only when every source and cache are unavailable.

Selecting a card uses its title to perform the existing Sonarr lookup; the catalogue provider ID is never treated as a TVDB ID unless the response explicitly includes a valid TVDB identifier. This preserves correct Sonarr metadata and exact season/episode download scope.

## Configuration and safety

The provider uses the already configured `YTS_OFFICIAL_TV_URL`, accepts only HTTPS from that origin, and does not expose raw upstream HTML, magnets, credentials, or service keys. It does not start the media stack. Cache cleanup must preserve `trending-tv.json`.

## Acceptance

- Empty TV Show tab renders trending cards from YTS Official.
- Empty primary response falls back to popular; unavailable live responses fall back to cache.
- Cached output sets `stale: true` and the cache chip.
- Search and clearing search continue to work.
- A trending card opens the correct Sonarr lookup flow.
- Concurrent backend requests make one upstream call per fallback step.
- Cache cleanup never removes `trending-tv.json`.
- Backend, host-controller, Flutter analyze/test/build Windows, Compose validation, and a non-downloading runtime query pass.
