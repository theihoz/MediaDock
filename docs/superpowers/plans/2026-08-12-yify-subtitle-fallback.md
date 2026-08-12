# YIFY Subtitle Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Bazarr-first subtitle search with an optional, isolated YIFY Direct fallback and a usable Flutter selection flow.

**Architecture:** Keep Bazarr as the source of truth. Add a provider abstraction and signed short-lived download tokens in the Node backend; YIFY Direct is disabled by default and may be invoked explicitly or after an empty Bazarr result. Flutter selects a library movie and controls language/provider/fallback without handling service credentials or arbitrary download URLs.

**Tech Stack:** Node.js 22 built-in HTTP/fetch/test/crypto, Bazarr/Jellyfin APIs, Flutter Windows, Docker Compose.

## Global Constraints

- Bazarr remains the only automatic/background subtitle source.
- YIFY Direct defaults to disabled and never bypasses CAPTCHA or browser challenges.
- Only library movies may be searched or written.
- Accepted subtitle formats are `.srt`, `.vtt`, and `.ass`; archives must reject path traversal.
- Flutter never receives internal API keys, provider cookies, arbitrary destination paths, or raw authenticated URLs.
- Use TDD for every behavior change.

---

### Task 1: Provider normalization and fallback policy

**Files:**
- Create: `backend/src/subtitle-providers.mjs`
- Create: `backend/test/subtitle-providers.test.mjs`

**Interfaces:**
- Produces: `normalizeSubtitle(value, source)`, `mergeSubtitleResults(groups)`, `shouldUseDirectFallback(options, bazarrResults)`, `filterSubtitleResults(items, language, provider)`.

- [ ] Write failing tests proving language/provider filtering, duplicate merging, and fallback only when enabled with no Bazarr matches.
- [ ] Run `node --test backend/test/subtitle-providers.test.mjs` and confirm missing exports fail.
- [ ] Implement the four pure functions with stable normalized fields: `id`, `provider`, `source`, `language`, `release`, `score`, `hearingImpaired`, `format`, `downloadToken`.
- [ ] Run the test and confirm all cases pass.

### Task 2: Short-lived download tokens

**Files:**
- Create: `backend/src/subtitle-token.mjs`
- Create: `backend/test/subtitle-token.test.mjs`

**Interfaces:**
- Produces: `createSubtitleToken(payload, secret, now?)` and `verifySubtitleToken(token, secret, now?)`.

- [ ] Write failing tests for valid token round-trip, tampering, expiry, and a token that contains no provider URL in readable form.
- [ ] Run the focused test and confirm failure.
- [ ] Implement HMAC-SHA256 signed tokens with a five-minute expiry and strict payload validation.
- [ ] Run the focused test and confirm pass.

### Task 3: Bazarr-first search API and library movie selector

**Files:**
- Modify: `backend/src/media-clients.mjs`
- Modify: `backend/src/server.mjs`
- Modify: `backend/test/media-clients.test.mjs`

**Interfaces:**
- Produces: `GET /v1/library/subtitle-media` and enhanced `GET /v1/library/{id}/subtitles/search?language=&provider=&directFallback=`.
- Consumes: normalization/fallback functions from Task 1.

- [ ] Write failing tests for extracting Radarr movies from Bazarr and filtering Bazarr results by language/provider.
- [ ] Run tests and confirm the new behavior fails.
- [ ] Add `subtitleMedia()` and normalized Bazarr search behavior; validate `vi|en` and known provider values.
- [ ] Register the new route and return `400 invalid_request` for invalid query values.
- [ ] Run all backend tests.

### Task 4: Isolated YIFY Direct adapter

**Files:**
- Create: `backend/src/yify-direct.mjs`
- Create: `backend/test/yify-direct.test.mjs`
- Modify: `backend/src/server.mjs`

**Interfaces:**
- Produces: `YifyDirectProvider.search(movie, language)` and `YifyDirectProvider.download(downloadToken, target)`.

- [ ] Write failing tests using injected fetch for disabled mode, metadata mismatch, timeout/provider challenge, normalized search results, and safe subtitle download.
- [ ] Confirm focused tests fail.
- [ ] Implement the adapter with injected fetch, fixed configured base URL, timeout, response size limits, content-type/extension checks, and `provider_unavailable` errors.
- [ ] Add explicit YIFY search route and optional fallback composition. Keep disabled-mode behavior deterministic without external calls.
- [ ] Run focused and full backend tests.

### Task 5: Safe file installation and refresh

**Files:**
- Create: `backend/src/subtitle-files.mjs`
- Create: `backend/test/subtitle-files.test.mjs`
- Modify: `backend/src/media-clients.mjs`
- Modify: `backend/src/server.mjs`

**Interfaces:**
- Produces: `safeSubtitleName(videoPath, language, extension)`, `validateSubtitlePayload(buffer, format)`, and direct-download handling through `POST /v1/library/{id}/subtitles/download`.

- [ ] Write failing tests for `.vi.srt`/`.en.srt` naming, unsupported extensions, oversized payloads, and traversal-like names.
- [ ] Confirm failures.
- [ ] Implement atomic temporary-file installation limited to the movie directory; backend derives destination from Bazarr metadata.
- [ ] Trigger Bazarr scan-disk and Jellyfin library refresh after successful installation.
- [ ] Run all backend tests.

### Task 6: Bootstrap settings

**Files:**
- Modify: `.env.example`
- Modify: `docker-compose.yml`
- Modify: `scripts/bootstrap.sh`
- Modify: `scripts/auto-configure.ps1`

**Interfaces:**
- Produces environment variables `YIFY_DIRECT_ENABLED=false`, `YIFY_DIRECT_BASE_URL`, `SUBTITLE_TOKEN_SECRET`.

- [ ] Add environment/configuration validation without logging secret values.
- [ ] Generate `SUBTITLE_TOKEN_SECRET` idempotently when absent.
- [ ] Pass settings only to backend and retain Bazarr providers/profile configuration.
- [ ] Run `docker compose --env-file .env.compose config --quiet` twice and verify no config duplication.

### Task 7: Flutter subtitle workflow

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Modify: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: subtitle-media/search/download/refresh endpoints from Tasks 3–5.

- [ ] Write failing widget tests for movie dropdown, language/provider selectors, direct fallback switch, and the two search buttons.
- [ ] Confirm widget tests fail.
- [ ] Replace manual Radarr ID entry with library movie selection and add provider/fallback controls.
- [ ] Render normalized result metadata and preserve download/refresh error feedback.
- [ ] Run `flutter analyze`, `flutter test --no-pub -r expanded`, and `flutter build windows --release`.

### Task 8: Integration verification

**Files:**
- Modify: `README.md`

**Interfaces:**
- Verifies the complete feature without adding new runtime interfaces.

- [ ] Rebuild backend with `docker compose --env-file .env.compose up -d --build api`.
- [ ] Verify YIFY Direct disabled mode makes no direct call and Bazarr search still works for the Big Buck Bunny test movie.
- [ ] Verify subtitle delete/restore/refresh and Jellyfin recognition.
- [ ] Verify 12 services running, zero unhealthy, host-controller token guard `401`, and no credential fields in gateway responses.
- [ ] Document the setting, provider behavior, and lawful-use limitation in README.
- [ ] Run all Node tests, Flutter checks/build, Compose validation, and live health checks once more.

## Self-review

- Coverage: architecture, fallback behavior, UI, security, refresh, configuration, and acceptance tests are mapped to Tasks 1–8.
- Placeholder scan: no deferred implementation markers remain.
- Type consistency: normalized result fields and token/file interfaces match across tasks.
- Repository note: this workspace has no `.git`, so commit steps are intentionally omitted; changes remain local.
