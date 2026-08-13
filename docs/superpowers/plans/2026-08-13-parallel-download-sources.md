# Parallel Download Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Search YTS, EZTV, and enabled Free & Public Domain indexers concurrently, then let the user choose a valid source and release.

**Architecture:** `MediaClients` will issue independent bounded Arr/provider searches and merge their normalized releases. The API retains its release array contract. Flutter derives tabs only from release sources with at least one actionable result, so unavailable sources remain invisible.

**Tech Stack:** Node.js backend, Radarr/Sonarr/Prowlarr, Flutter Windows.

## Global Constraints

- Keep opaque download tokens and credentials out of Flutter responses and logs.
- One failed or slow source must not fail the remaining source results.
- Default release searches remain bounded by the existing 15-second request budget.
- Do not start the media stack automatically.

### Task 1: Parallel release aggregation

**Files:**
- Modify: `backend/src/media-clients.mjs`
- Test: `backend/test/media-clients.test.mjs`

**Interfaces:**
- Produces: `MediaClients.releases(tmdbId, { freePublicDomain })` and `MediaClients.seriesReleases(tvdbId, selection)` returning merged normalized releases.

- [ ] Write failing tests that prove movie and TV searches merge successful source results when another source fails.
- [ ] Run `node --test backend/test/media-clients.test.mjs` and confirm the new tests fail.
- [ ] Implement independent source searches with `Promise.allSettled`, retaining only actionable releases.
- [ ] Run the backend test file and confirm it passes.

### Task 2: Source selector in Flutter

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Test: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: normalized release rows containing `source` and `rejected`.
- Produces: source tabs that show only sources with actionable releases.

- [ ] Write a widget test that verifies only available source tabs appear and selecting one filters releases.
- [ ] Run `flutter test test/widget_test.dart` and confirm the new test fails.
- [ ] Implement a reusable source-filter selector for movie and TV release views.
- [ ] Run Flutter tests and analysis.

### Task 3: Runtime verification

**Files:**
- Modify: `docker-compose.yml` only if required by the backend build.

- [ ] Validate Compose with `docker compose config --quiet`.
- [ ] Rebuild only the API after the user’s already-running stack is left otherwise unchanged.
- [ ] Query a local movie release endpoint and verify it responds without an upstream timeout.
