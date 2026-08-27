# Season Vietsub Auto Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one season action automatically find and download the best Vietnamese subtitle for every imported episode still missing Vietsub.

**Architecture:** Add a coalesced backend season batch around the existing Bazarr episode search/download methods, expose one authenticated route, then make Flutter call it and reload catalog/season coverage. Keep manual per-episode controls intact.

**Tech Stack:** Node.js ESM backend and node:test, Flutter/Dart widget tests, Sonarr API, Bazarr API, Jellyfin API.

## Global Constraints

- Providers stay concurrent through Bazarr: Gestdown, YIFY Subtitles, and configured OpenSubtitles.com.
- Vietnamese is the fixed primary language for the season action; English is not counted as Vietsub.
- Existing Vietnamese subtitles are never replaced.
- Only imported episodes from the selected season are processed.
- Credentials, provider URLs, and internal API keys never reach Flutter or logs.
- Media stack startup behavior remains manual.

---

### Task 1: Backend season batch

**Files:**
- Modify: `backend/test/media-clients.test.mjs`
- Modify: `backend/src/media-clients.mjs`

**Interfaces:**
- Consumes: `subtitleSeason(seriesId, seasonNumber)`, `searchEpisodeSubtitles(episodeId, 'vi')`, `downloadEpisodeSubtitle(episodeId, result)`, `refreshEpisodeSubtitles(episodeId)`, `refreshJellyfin()`.
- Produces: `searchSeasonSubtitles(seriesId, seasonNumber)` returning `{seriesId, seasonNumber, total, alreadyAvailable, downloaded, unavailable, failed}`.

- [ ] **Step 1: Write failing backend tests**

Add tests proving the batch skips existing Vietsub, chooses the highest-scoring Vietnamese result, continues after empty/error results, limits work to the selected season, and coalesces duplicate in-flight requests.

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test backend/test/media-clients.test.mjs`

Expected: FAIL because `searchSeasonSubtitles` does not exist.

- [ ] **Step 3: Implement the batch minimally**

Add an in-flight map keyed by `seriesId:seasonNumber`, a bounded worker pool, per-episode result isolation, and aggregate counts. Sort candidate results by numeric score descending before calling the existing download method. Refresh successful episodes and Jellyfin after the batch.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `node --test backend/test/media-clients.test.mjs`

Expected: PASS.

### Task 2: Authenticated route

**Files:**
- Modify: `backend/test/media-clients.test.mjs`
- Modify: `backend/src/server.mjs`

**Interfaces:**
- Consumes: `MediaClients.searchSeasonSubtitles(seriesId, seasonNumber)`.
- Produces: `POST /v1/library/subtitle-media/{seriesId}/seasons/{seasonNumber}/search` with HTTP 202 aggregate response.

- [ ] **Step 1: Write a failing route contract test**

Exercise the real server route with numeric identifiers and assert the aggregate response. Assert malformed identifiers do not match the route.

- [ ] **Step 2: Run route tests and verify RED**

Run: `node --test backend/test/media-clients.test.mjs`

Expected: FAIL with route not found.

- [ ] **Step 3: Add the route**

Place the POST route next to the existing season GET route and forward only route-derived numeric identifiers.

- [ ] **Step 4: Run backend tests and verify GREEN**

Run: `node --test backend/test/*.test.mjs host-controller/test/*.test.mjs`

Expected: all tests pass.

### Task 3: Flutter season action

**Files:**
- Modify: `flutter_app/test/widget_test.dart`
- Modify: `flutter_app/lib/main.dart`

**Interfaces:**
- Consumes: season POST endpoint and existing subtitle catalog/season GET endpoints.
- Produces: `Tìm Vietsub cho Season N` action, aggregate result message, and refreshed `Vietsub x/y` chip.

- [ ] **Step 1: Write a failing widget test**

Select a TV season, tap the season action, assert exactly one season POST request, no per-episode search requests, aggregate feedback, and refreshed coverage.

- [ ] **Step 2: Run widget test and verify RED**

Run: `flutter test test/widget_test.dart --plain-name "searches Vietsub for the selected season in one action"`

Expected: FAIL because the season button/endpoint call does not exist.

- [ ] **Step 3: Implement the Flutter action**

Add batch state and `searchSeason()`. While a season is selected, make the primary filled button call the season endpoint. On completion reload the catalog, preserve series/season selection, reload season episodes, and show aggregate counts. Retain manual episode selection/search as a secondary action.

- [ ] **Step 4: Run Flutter checks and verify GREEN**

Run: `flutter test && flutter analyze && flutter build windows --release`

Expected: tests pass, no analyzer issues, Windows release builds.

### Task 4: Runtime and scope verification

**Files:**
- No production edits expected.

**Interfaces:**
- Validates the completed backend/UI contract and repository scope.

- [ ] **Step 1: Validate Compose and API health**

Run: `docker compose config --quiet`

Run: `Invoke-RestMethod http://127.0.0.1:3000/health`

Expected: Compose exits 0 and API reports `ready`.

- [ ] **Step 2: Run GitNexus change detection**

Run `detect_changes(scope: "unstaged")`, review affected processes, and report unrelated pre-existing dirty-worktree changes separately.

- [ ] **Step 3: Review sensitive output**

Confirm test/runtime output contains no OpenSubtitles password, provider credential, Bazarr API key, or raw subtitle download URL.
