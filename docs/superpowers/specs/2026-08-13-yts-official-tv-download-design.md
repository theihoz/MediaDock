# YTS Official TV Show Download Design

## Goal

Replace EZTV as the TV Show release provider with the public TV torrent endpoint exposed by `https://en.yts-official.com/`. Sonarr remains responsible for series metadata, monitoring, completed-download import, naming, Bazarr integration, and Jellyfin notification.

Movies continue to use the existing YTS/Radarr flow. This change applies only to TV Show release search and download.

## Provider boundary

Create a dedicated backend client for YTS Official. It calls:

`GET /?api=torrents&mode=tv&name={title}&year={year}&quality=all`

The client accepts only HTTPS responses from the configured origin, applies a 15-second timeout, validates the JSON shape, and normalizes each result without returning `magnetUrl` to Flutter. Normalized releases contain an opaque signed download token, title, quality, codec, byte size, peer/seed information, source `YTS Official`, and the inferred season/episode scope.

Release searches are cached for 10 minutes and coalesced by series TVDB ID plus season or episode selection.

## Exact-scope filtering

Season searches accept only packs that identify the selected season. Full-series collections, ranges such as `S01-S05`, other seasons, and individual episodes are excluded.

Episode searches accept only releases that identify the selected `SxxExx`. Packs and releases for other episodes are excluded.

If no exact match remains, the backend returns `yts_tv_release_unavailable`. It does not fall back to EZTV and does not silently download a broader pack.

## Download flow

1. Flutter requests releases for the selected Sonarr series, season, or episode.
2. Backend resolves the Sonarr series metadata and searches YTS Official using its title and year.
3. Flutter displays normalized releases and submits only the signed opaque token.
4. Backend verifies the token and confirms it matches the requested TVDB ID and scope.
5. Backend monitors only the selected Sonarr episode or season.
6. Backend submits the server-held magnet directly to qBittorrent with category `series`, pausing nothing else and never exposing the magnet to Flutter or logs.
7. Sonarr observes the completed `series` download, imports and renames it under `/data/library/series`, then notifies Jellyfin through the existing Connect integration.

The API responds only after qBittorrent accepts the magnet. Duplicate submissions are rejected using the torrent info hash already present in qBittorrent.

## API and UI

Existing series endpoints remain stable:

- `GET /v1/series/{tvdbId}/releases?seasonNumber=...`
- `GET /v1/series/{tvdbId}/releases?episodeId=...`
- `POST /v1/series/{tvdbId}/download`

The download body changes from raw `guid/indexerId` to `{ downloadToken }`. Legacy Sonarr release fields are rejected for TV downloads after migration.

Flutter labels every TV release `YTS Official`, displays quality, codec, size, peers/seeds, and shows a Vietnamese message when the selected scope is unavailable. Success remains `Đã gửi sang Sonarr/qBittorrent`.

## Bootstrap and configuration

Add configurable values for the YTS Official base URL, enabled state, token secret, timeout, and cache TTL. Secrets remain in `.env` and are not exposed to Flutter.

Bootstrap idempotently disables the EZTV Prowlarr indexer without deleting it. Prowlarr remains active for the movie/Radarr flow. Existing media containers retain `restart: "no"`; this feature does not start the stack automatically.

## Failure handling

- Provider timeout or non-JSON response: `yts_tv_provider_unavailable`.
- No exact scope match: `yts_tv_release_unavailable`.
- Invalid, expired, or cross-series token: `invalid_download_token`.
- Duplicate torrent: return its existing hash and an idempotent accepted response.
- qBittorrent rejection: return `download_client_rejected`; do not report success.
- Sonarr monitoring failure: do not submit the magnet.

Errors and logs never contain magnet URLs, provider HTML, API credentials, or service API keys.

## Tests and acceptance

- Provider normalization removes raw magnets and creates signed tokens.
- Season filtering rejects full-series ranges, individual episodes, and wrong seasons.
- Episode filtering accepts only the exact selected episode.
- Concurrent identical searches make one upstream request and cache for 10 minutes.
- Download token tampering, expiry, and cross-scope reuse are rejected.
- Only the chosen Sonarr scope is monitored before qBittorrent submission.
- qBittorrent receives the magnet with category `series` and duplicate requests remain idempotent.
- EZTV is disabled idempotently and never queried by the TV Show backend flow.
- Flutter covers release display, unavailable state, and successful token submission.
- Full Node tests, Flutter analyze/test/build Windows, Compose validation, and a non-downloading runtime provider query pass.

No copyrighted sample download is initiated during automated verification.
