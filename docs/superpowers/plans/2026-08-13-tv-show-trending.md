# TV Show Trending Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display a resilient YTS Official TV Show trending catalogue when the TV tab opens.

**Architecture:** Extend the YTS Official TV provider with normalized catalogue lookup and a small last-good JSON store. The API exposes a stable series trending response and Flutter renders it only while the series search input is empty, keeping existing Sonarr search and YTS download behavior unchanged.

**Tech Stack:** Node.js 22 ESM, built-in fetch/fs, Flutter Windows, Docker Compose, host-controller tests.

## Global Constraints

- Live source chain is `trending → popular → cache` on YTS Official TV mode.
- Only HTTPS YTS Official responses are accepted; timeout is 15 seconds.
- Cache path is `/data/cache/trending-tv.json` and cleanup preserves it.
- No magnets, credentials, upstream HTML, or service keys reach Flutter/logs.
- The media stack does not start automatically.

---

### Task 1: Provider catalogue and cache

**Files:**
- Modify: `backend/src/yts-official-tv.mjs`
- Modify: `backend/test/yts-official-tv.test.mjs`

**Interfaces:**
- Produces: `YtsOfficialTvProvider.trending() -> { items, stale, source }`.
- Provider constructor accepts `cachePath` and uses one in-flight request per trending operation.

- [ ] **Step 1: Write failing tests**

Add tests for primary `api=trending&mode=tv`, popular fallback when primary is empty, cached fallback when live calls fail, and normalized card output without unsafe provider fields.

- [ ] **Step 2: Confirm RED**

Run: `node --test backend/test/yts-official-tv.test.mjs`

Expected: FAIL because `trending()` does not exist.

- [ ] **Step 3: Implement minimal provider catalogue flow**

Add a bounded `catalogue(type)` request, normalize title/name and date fields into a series discovery card, atomically save live cards to `cachePath`, return `stale:true` for cached data, and coalesce concurrent `trending()` calls.

- [ ] **Step 4: Confirm GREEN and commit**

Run: `node --test backend/test/yts-official-tv.test.mjs`

```powershell
git add backend/src/yts-official-tv.mjs backend/test/yts-official-tv.test.mjs
git commit -m "feat: add TV show trending fallback"
```

### Task 2: API, configuration and cleanup protection

**Files:**
- Modify: `backend/src/server.mjs`
- Modify: `host-controller/src/maintenance.mjs`
- Modify: `host-controller/test/maintenance.test.mjs`
- Modify: `docker-compose.yml`

**Interfaces:**
- Produces: `GET /v1/series/trending` returning `{ items, stale, source }`.
- API provider receives cache path `/data/cache/trending-tv.json`.

- [ ] **Step 1: Write failing tests**

Add API route coverage through the route test pattern if available, and add a maintenance test that `trending-tv.json` is never deleted by manual or scheduled cache cleanup.

- [ ] **Step 2: Confirm RED**

Run: `node --test host-controller/test/*.test.mjs backend/test/*.test.mjs`

- [ ] **Step 3: Implement API and protection**

Instantiate the provider with `TRENDING_TV_CACHE`, add the GET route, and extend the cache preservation predicate with the exact `trending-tv.json` basename.

- [ ] **Step 4: Confirm GREEN and commit**

Run: `node --test host-controller/test/*.test.mjs backend/test/*.test.mjs`

Run: `docker compose --env-file .env.compose config --quiet`

```powershell
git add backend/src/server.mjs host-controller/src/maintenance.mjs host-controller/test/maintenance.test.mjs docker-compose.yml
git commit -m "feat: expose protected TV show trending"
```

### Task 3: Flutter TV trending grid

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Modify: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: `/v1/series/trending` response `{ items, stale, source }`.

- [ ] **Step 1: Write failing widget tests**

Make the fake API return a TV trending card. Assert opening TV Show calls the endpoint, renders `Đang thịnh hành`, shows `Phổ biến trên YTS Official` for popular fallback, and clearing a search restores the trending grid.

- [ ] **Step 2: Confirm RED**

Run: `flutter test test/widget_test.dart`

- [ ] **Step 3: Implement minimal TV trending UI**

Load trending during TV tab initialization, retain it while searching, render a responsive card/list using the existing series item opening behavior, and map source states to the three Vietnamese chips from the approved design.

- [ ] **Step 4: Confirm GREEN and commit**

Run: `flutter test test/widget_test.dart`

```powershell
git add flutter_app/lib/main.dart flutter_app/test/widget_test.dart
git commit -m "feat: show trending TV series"
```

### Task 4: Full verification and runtime read-only query

**Files:**
- No production changes expected.

- [ ] **Step 1: Run Node and Flutter verification**

Run: `node --test backend/test/*.test.mjs host-controller/test/*.test.mjs`

Run: `flutter analyze`

Run: `flutter test`

Run: `flutter build windows`

- [ ] **Step 2: Rebuild only API and verify runtime**

Run: `docker compose --env-file .env.compose build api`

Run: `docker compose --env-file .env.compose up -d --no-deps api`

Call `GET /v1/series/trending`; verify cards are returned with no magnet field. Do not POST a download.

- [ ] **Step 3: Check final diff**

Run: `git diff --check` and `git status --short`; preserve the user-owned `README.md` change.
