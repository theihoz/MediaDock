# Unified Media Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one responsive search experience for movies and TV shows with aliases, people, studios, networks, filters, suggestions, caching, and recent searches.

**Architecture:** A focused backend search module queries Arr and Seerr metadata concurrently, normalizes and deduplicates results, and exposes one discovery endpoint. Flutter uses a dedicated controller for debounce, stale-response protection, session caching, filters, suggestions, and local history.

**Tech Stack:** Node.js 22, Radarr/Sonarr/Jellyseerr APIs, Flutter Windows, Node test runner, Flutter test.

## Global Constraints

- Debounce is 400 ms and provider cache TTL is 5 minutes.
- Queries shorter than 2 characters do not call providers.
- One provider failure returns partial results from working providers.
- No new metadata API key, no credential exposure, and no automatic download.
- Media stack remains manually started.

---

### Task 1: Backend unified search

**Files:**
- Create: `backend/src/unified-search.mjs`
- Create: `backend/test/unified-search.test.mjs`
- Modify: `backend/src/server.mjs`

**Interfaces:**
- Produces: `UnifiedSearch.search({ query, type, year, library, limit })` returning `{items, partial, sources, query}`.

- [ ] Write failing tests for short-query suppression, concurrent movie/series merge, deduplication, filters, aliases/matched reason, partial failure, cache, and in-flight coalescing.
- [ ] Run `node --test backend/test/unified-search.test.mjs` and verify expected failures.
- [ ] Implement normalization, bounded concurrent providers, deduplication, filters, TTL cache, and request coalescing.
- [ ] Add `GET /v1/discover/search` validation and response handling.
- [ ] Run backend tests and verify green.

### Task 2: Flutter search controller

**Files:**
- Create: `flutter_app/lib/unified_search_controller.dart`
- Create: `flutter_app/test/unified_search_controller_test.dart`

**Interfaces:**
- Produces: `UnifiedSearchController`, its immutable state, debounce, stale response protection, filters, cache, and recent history.

- [ ] Write failing controller tests for 400 ms debounce, minimum length, stale responses, filters, cache, and ten-item history.
- [ ] Run controller tests and verify expected failures.
- [ ] Implement the controller using injectable API and history storage callbacks.
- [ ] Run controller tests and verify green.

### Task 3: Unified discovery UI

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Modify: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: `UnifiedSearchController` and `/v1/discover/search`.
- Produces: one shared search bar, eight-item suggestion overlay, result tabs, match reason, filters, and recent searches.

- [ ] Write failing widget tests for live suggestions, movie/TV labels, filtering, clear-to-trending, partial state, and recent history.
- [ ] Run widget tests and verify expected failures.
- [ ] Replace duplicated movie/TV search inputs with the shared search surface while preserving existing detail pages.
- [ ] Run Flutter tests and analyze.

### Task 4: Runtime verification

**Files:**
- No additional production files.

- [ ] Run all Node and Flutter tests plus `docker compose config --quiet`.
- [ ] Build Flutter Windows.
- [ ] Rebuild only `api` and smoke-test title, alias, person, studio, and TV queries.
