# Vietsub Series/Season Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group TV subtitle management by series and season and configure Vietnamese-first OpenSubtitles.com, Gestdown, and YIFY Subtitles.

**Architecture:** Sonarr supplies imported series/episode structure, while Bazarr supplies subtitle coverage and search/download actions. The compact catalog endpoint returns series/season summaries; a separate lazy endpoint returns episodes for one selected season.

**Tech Stack:** Node.js HTTP API, Sonarr/Bazarr APIs, Python/PowerShell bootstrap, Flutter Windows.

## Global Constraints

- OpenSubtitles credentials stay only in private `.env` and Bazarr config.
- Vietnamese is required; English is fallback only.
- Do not enable AnimeTosho, AnimeKalesi, or AnimeSubInfo; keep YIFY Subtitles enabled.
- Do not auto-start the media stack.

---

### Task 1: Provider reconciliation

**Files:**
- Modify: `.env.example`
- Modify: `scripts/bazarr_profile.py`
- Modify: `scripts/auto-configure.ps1`
- Test: `scripts/test_bazarr_profile.py`
- Test: `host-controller/test/bootstrap-config.test.mjs`

**Interfaces:**
- Consumes: `OPENSUBTITLES_USERNAME`, `OPENSUBTITLES_PASSWORD`.
- Produces: Bazarr `enabled_providers` containing Gestdown, YIFY Subtitles, and credentialed OpenSubtitles.com.

- [ ] Write tests for the provider list with and without OpenSubtitles credentials.
- [ ] Run tests and confirm the current YIFY list fails them.
- [ ] Reconcile provider credentials without printing their values.
- [ ] Run Python and bootstrap tests.

### Task 2: Compact subtitle catalog API

**Files:**
- Modify: `backend/src/media-clients.mjs`
- Modify: `backend/src/server.mjs`
- Test: `backend/test/media-clients.test.mjs`

**Interfaces:**
- Produces: `subtitleMedia(): Array<Movie|SeriesSummary>`.
- Produces: `subtitleSeason(seriesId, seasonNumber): Array<Episode>`.

- [ ] Write failing tests proving the catalog contains series summaries but no episode rows.
- [ ] Write a failing test proving season detail contains only imported episodes in that season and Vietnamese coverage is independent from English.
- [ ] Implement Sonarr/Bazarr joining with graceful degraded coverage.
- [ ] Add the lazy season route and run backend tests.

### Task 3: Flutter grouped interaction

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Test: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: compact catalog and lazy season endpoint from Task 2.

- [ ] Write a failing widget test for one series card and compact season rows.
- [ ] Write a failing widget test for lazy episode loading and missing-Vietsub-first ordering.
- [ ] Implement series/season expansion while preserving movie behavior.
- [ ] Run Flutter tests and analyze.

### Task 4: Runtime application and verification

**Files:**
- Modify: `README.md`

- [ ] Re-run bootstrap through the user-initiated flow without exposing credentials.
- [ ] Rebuild API and query compact series coverage plus one season.
- [ ] Run all Node, Python, Flutter tests, `flutter analyze`, Windows release build, and `docker compose config --quiet`.
- [ ] Run GitNexus `detect_changes` and review affected release/subtitle flows.
