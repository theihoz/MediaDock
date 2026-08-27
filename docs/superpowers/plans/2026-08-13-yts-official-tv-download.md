# YTS Official TV Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Search exact TV season/episode torrents through YTS Official and submit the selected magnet securely to qBittorrent for Sonarr import.

**Architecture:** Add a focused YTS Official provider that normalizes and signs server-held magnet selections. `MediaClients` resolves Sonarr metadata and scope, delegates release discovery to the provider, monitors only the selected scope, then submits the verified magnet to qBittorrent under category `series`. Flutter consumes opaque release tokens and never sees magnets.

**Tech Stack:** Node.js 22 ESM, built-in `fetch`/`crypto`, qBittorrent Web API, Sonarr API v3, Flutter Windows, PowerShell bootstrap, Docker Compose.

## Global Constraints

- TV Show release discovery uses only `https://en.yts-official.com/`; no EZTV fallback.
- Exact season and episode filtering must reject full-series collections and wrong scopes.
- Upstream timeout is 15 seconds and release cache TTL is 10 minutes.
- Magnet URLs, credentials, and service API keys never reach Flutter or logs.
- qBittorrent category is exactly `series`.
- Media containers retain `restart: "no"` and bootstrap does not start the stack.
- Automated verification must not initiate a copyrighted sample download.

---

### Task 1: Secure YTS Official TV provider

**Files:**
- Create: `backend/src/yts-official-tv.mjs`
- Create: `backend/test/yts-official-tv.test.mjs`

**Interfaces:**
- Produces: `YtsOfficialTvProvider`, `normalizeTvTorrent`, `filterTvTorrents`, `createTvDownloadToken`, `verifyTvDownloadToken`.
- Provider method: `search({ tvdbId, title, year, seasonNumber?, episodeNumber? }) -> Promise<NormalizedRelease[]>`.
- Provider method: `resolveToken(token, expectedScope) -> { magnetUrl, title, infoHash }`.

- [ ] **Step 1: Write failing provider tests**

Test that exact `S02` packs and `S02E03` episodes survive filtering, while `S01-S05`, individual episodes in season-pack mode, wrong seasons, and wrong episodes are removed. Test normalization returns `downloadToken` but no `magnetUrl`, and token tampering/cross-scope reuse fails.

- [ ] **Step 2: Run the tests and confirm RED**

Run: `node --test backend/test/yts-official-tv.test.mjs`

Expected: FAIL because `backend/src/yts-official-tv.mjs` does not exist.

- [ ] **Step 3: Implement the provider**

Use `URLSearchParams({ api:'torrents', mode:'tv', name:title, year:String(year), quality:'all' })`, an `AbortController` set to 15 seconds, strict HTTPS/origin validation, bounded response parsing, exact title-scope regexes, HMAC-SHA256 tokens with five-minute expiry, and a server-side token payload containing the magnet. Return only normalized public fields plus the signed token.

- [ ] **Step 4: Verify GREEN**

Run: `node --test backend/test/yts-official-tv.test.mjs`

Expected: all provider tests pass.

- [ ] **Step 5: Commit provider**

```powershell
git add backend/src/yts-official-tv.mjs backend/test/yts-official-tv.test.mjs
git commit -m "feat: add secure YTS Official TV provider"
```

### Task 2: Connect Sonarr scope and qBittorrent submission

**Files:**
- Modify: `backend/src/media-clients.mjs`
- Modify: `backend/src/server.mjs`
- Modify: `backend/test/media-clients.test.mjs`

**Interfaces:**
- Consumes: `YtsOfficialTvProvider.search()` and `resolveToken()` from Task 1.
- Produces: existing series releases endpoint returning YTS Official releases and download endpoint accepting `{ downloadToken, episodeId? , seasonNumber? }`.

- [ ] **Step 1: Write failing integration-unit tests**

Test that `seriesReleases` passes Sonarr title/year plus exact episode number to the provider; `downloadSeriesRelease` rejects legacy `guid/indexerId`, monitors only the selected scope, resolves a same-scope token, detects an existing info hash, and otherwise posts `urls=<magnet>&category=series` to `/torrents/add`.

- [ ] **Step 2: Run tests and confirm RED**

Run: `node --test backend/test/media-clients.test.mjs`

Expected: FAIL because series methods still call Sonarr `/release` and accept legacy fields.

- [ ] **Step 3: Implement provider-backed series methods**

Inject `tvProvider` into `MediaClients`; resolve Sonarr episode metadata for episode searches; preserve the existing 10-minute coalescing cache; verify token scope before monitoring; use the existing qBittorrent authenticated client to inspect hashes and submit the magnet. Return `{ accepted:true, duplicate:boolean, hash }` without the magnet.

- [ ] **Step 4: Map stable API errors**

In `server.mjs`, instantiate the provider from `YTS_OFFICIAL_TV_URL`, `YTS_OFFICIAL_TV_ENABLED`, and `TV_DOWNLOAD_TOKEN_SECRET`. Translate typed provider failures to `yts_tv_provider_unavailable`, `yts_tv_release_unavailable`, `invalid_download_token`, and `download_client_rejected` without returning raw upstream text.

- [ ] **Step 5: Verify GREEN and commit**

Run: `node --test backend/test/*.test.mjs`

```powershell
git add backend/src/media-clients.mjs backend/src/server.mjs backend/test/media-clients.test.mjs
git commit -m "feat: download TV releases from YTS Official"
```

### Task 3: Flutter token contract and provider states

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Modify: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: release `{ downloadToken,title,quality,codec,size,seeders,peers,source }`.
- Sends: `{ downloadToken, episodeId? , seasonNumber? }`.

- [ ] **Step 1: Write failing widget tests**

Update the fake gateway to return YTS Official token releases. Assert `YTS Official` is rendered, the POST body contains no `guid` or `indexerId`, and unavailable provider responses render the Vietnamese retry message.

- [ ] **Step 2: Run and confirm RED**

Run: `flutter test test/widget_test.dart`

Expected: FAIL because Flutter still submits Sonarr fields.

- [ ] **Step 3: Implement token UI**

Show the provider in the release subtitle, submit `downloadToken`, preserve exact scope fields, and map `yts_tv_release_unavailable`/`yts_tv_provider_unavailable` to concise Vietnamese errors.

- [ ] **Step 4: Verify GREEN and commit**

Run: `flutter test test/widget_test.dart`

```powershell
git add flutter_app/lib/main.dart flutter_app/test/widget_test.dart
git commit -m "feat: use YTS Official tokens for TV downloads"
```

### Task 4: Bootstrap and Compose configuration

**Files:**
- Modify: `scripts/auto-configure.ps1`
- Modify: `docker-compose.yml`
- Modify: `.env.example`
- Modify: `host-controller/test/bootstrap-config.test.mjs`

**Interfaces:**
- Produces environment values `YTS_OFFICIAL_TV_URL`, `YTS_OFFICIAL_TV_ENABLED`, and `TV_DOWNLOAD_TOKEN_SECRET`.

- [ ] **Step 1: Write failing bootstrap tests**

Assert bootstrap idempotently changes existing EZTV to `enable: false`, does not delete it, and Compose supplies the YTS Official provider environment without changing `restart: "no"`.

- [ ] **Step 2: Run and confirm RED**

Run: `node --test host-controller/test/bootstrap-config.test.mjs`

- [ ] **Step 3: Implement configuration**

Disable EZTV through its existing Prowlarr ID, preserve YTS movie configuration, generate `TV_DOWNLOAD_TOKEN_SECRET` if absent, and pass provider settings only to the API container.

- [ ] **Step 4: Verify and commit**

Run: `node --test host-controller/test/bootstrap-config.test.mjs`

Run: `docker compose --env-file .env.compose config --quiet`

```powershell
git add scripts/auto-configure.ps1 docker-compose.yml .env.example host-controller/test/bootstrap-config.test.mjs
git commit -m "chore: configure YTS Official TV provider"
```

### Task 5: Full verification and local rollout

**Files:**
- No production file changes expected.

**Interfaces:**
- Validates the complete feature without initiating a torrent download.

- [ ] **Step 1: Run all Node tests**

Run: `node --test backend/test/*.test.mjs host-controller/test/*.test.mjs`

Expected: zero failures.

- [ ] **Step 2: Run Flutter verification**

Run: `flutter analyze`

Run: `flutter test`

Run: `flutter build windows`

Expected: zero analyzer issues, zero test failures, Windows executable built.

- [ ] **Step 3: Validate Compose and diff**

Run: `docker compose --env-file .env.compose config --quiet`

Run: `git diff --check`

- [ ] **Step 4: Build and recreate only the running API**

Run: `docker compose --env-file .env.compose build api`

Run: `docker compose --env-file .env.compose up -d --no-deps api`

Confirm `/health` is `ready`, query a TV release list, and verify each result exposes a token but no magnet. Do not POST a real selection.

- [ ] **Step 5: Record final status**

Run: `git status --short` and preserve the user's unrelated `README.md` modification.
