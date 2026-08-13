# Nyaa Hybrid Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add resilient Nyaa.si and Nyaa.land movie/series sources that search concurrently with the existing providers and expose actionable source health without blocking the application.

**Architecture:** Prowlarr owns both Nyaa indexers and assigns the existing FlareSolverr proxy to each because runtime verification shows Cloudflare on both domains. Nyaa.land uses the same Nyaa schema with its base URL overridden. Backend release aggregation asks Arr for all enabled indexers concurrently, normalizes/deduplicates results, and reports each Nyaa endpoint separately in Services.

**Tech Stack:** PowerShell bootstrap, Prowlarr/Radarr/Sonarr APIs, Node.js ESM backend and `node:test`, Flutter Windows, Docker Compose.

## Global Constraints

- Nyaa.si timeout is 12 seconds; Nyaa.land timeout is 8 seconds.
- Nyaa is enabled for both movies and series and does not trigger automatic downloads.
- A Cloudflare/mirror failure must not fail a request when another source succeeds.
- No CAPTCHA solver service, browser cookie persistence, magnet exposure, API-key exposure, or paid anti-captcha integration.
- The stack remains manual-start only.

---

### Task 1: Idempotent Nyaa bootstrap

**Files:**
- Modify: `scripts/auto-configure.ps1`
- Test: `host-controller/test/bootstrap-config.test.mjs`

**Interfaces:**
- Consumes: Prowlarr `/indexer/schema`, `/indexer`, `/indexerProxy`, and existing `Set-Property`/`Invoke-Json` helpers.
- Produces: enabled `Nyaa.si` and `Nyaa.land` indexers tagged for Radarr/Sonarr; Nyaa.si references the FlareSolverr proxy.

- [ ] **Step 1: Write failing bootstrap behavior tests**

Add tests that execute the bootstrap reconciliation helpers with controlled Prowlarr fixtures and assert the resulting payloads contain exactly one Nyaa.si and one Nyaa.land, `baseUrl=https://nyaa.si/` and `baseUrl=https://nyaa.land/`, movie/TV categories, and FlareSolverr proxy only on Nyaa.si.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `node --test host-controller/test/bootstrap-config.test.mjs`

Expected: FAIL because no Nyaa hybrid reconciliation exists.

- [ ] **Step 3: Implement minimal reconciliation**

Use the Prowlarr `Nyaa` schema twice, give each instance a stable unique name, override its base URL field, attach the existing `flaresolverr` proxy tag/id only to Nyaa.si, enable movie and series categories, and update an existing indexer with PUT rather than creating duplicates. If the schema lacks an editable base URL, report `needs_manual_configuration` and continue bootstrap.

- [ ] **Step 4: Run focused test and verify GREEN**

Run: `node --test host-controller/test/bootstrap-config.test.mjs`

Expected: PASS.

### Task 2: Backend source registry and health states

**Files:**
- Modify: `backend/src/media-clients.mjs`
- Test: `backend/test/media-clients.test.mjs`

**Interfaces:**
- Consumes: `MediaClients.prowlarr('/indexer')` and indexer status/error metadata.
- Produces: source objects `{id,name,state,scopes,endpoint,reason?}` for `nyaa-si` and `nyaa-land`.

- [ ] **Step 1: Write failing source-health tests**

Create fixtures for ready Nyaa.si/Nyaa.land, an indexer failure containing a Cloudflare challenge, a temporary timeout, and a disabled indexer. Assert the public response maps them to `ready`, `cloudflare_blocked`, `degraded`, and `disabled` without returning raw HTML or credentials.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `node --test --test-name-pattern="Nyaa" backend/test/media-clients.test.mjs`

Expected: FAIL because the registry does not expose Nyaa sources.

- [ ] **Step 3: Implement minimal health normalization**

Extend `downloadSources()` with both Nyaa entries, safe endpoint labels, scope `['movie','series']`, and a small state mapper that recognizes Cloudflare/Turnstile text but emits only the stable `cloudflare_blocked` reason.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the same command and expect PASS.

### Task 3: Concurrent Nyaa release aggregation and deduplication

**Files:**
- Modify: `backend/src/media-clients.mjs`
- Test: `backend/test/media-clients.test.mjs`

**Interfaces:**
- Consumes: Radarr/Sonarr interactive release APIs and Arr indexer IDs discovered by exact configured source name.
- Produces: normalized releases with `source` set to `Nyaa.si` or `Nyaa.land`, opaque existing download tokens, and unique torrents.

- [ ] **Step 1: Write failing concurrent-search tests**

Add a movie case and a series case where Nyaa.si, Nyaa.land, and another source start before any resolves. Assert a slow/failing Nyaa.si does not suppress a successful Nyaa.land result. Add a duplicate fixture with the same info-hash from both endpoints and assert one release remains. Add an episode fixture proving a wrong season/episode is rejected.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `node --test --test-name-pattern="Nyaa|concurrent" backend/test/media-clients.test.mjs`

Expected: FAIL because the indexer selection and deduplication do not distinguish the two Nyaa endpoints.

- [ ] **Step 3: Implement minimal aggregation**

Discover enabled indexer IDs by `Nyaa.si` and `Nyaa.land`, launch their Arr requests alongside existing source promises, cap each branch independently, reuse `matchesTvTitleScope` for TV safety, and deduplicate by extracted info-hash with normalized-title/size/scope fallback.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the same command and expect PASS.

### Task 4: Flutter source presentation

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Test: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: `/v1/sources` Nyaa entries and existing normalized release `source` fields.
- Produces: separate Services cards/status copy and release chips only for sources with results.

- [ ] **Step 1: Write failing widget tests**

Pump Services with both Nyaa source objects and verify distinct cards, scopes, endpoints, and friendly Cloudflare/degraded labels. Pump a release list containing only Nyaa.land and assert only the Nyaa.land chip is rendered.

- [ ] **Step 2: Run focused Flutter tests and verify RED**

Run: `flutter test test/widget_test.dart --plain-name "Nyaa source states"`

Expected: FAIL because Nyaa-specific states/copy are absent.

- [ ] **Step 3: Implement minimal UI mapping**

Extend the existing state-label mapping; keep source groups derived from actual releases so empty Nyaa groups never render.

- [ ] **Step 4: Run focused Flutter tests and verify GREEN**

Run the focused test and expect PASS.

### Task 5: Runtime reconciliation and verification

**Files:**
- Modify only if runtime evidence exposes a defect in the preceding tasks.

**Interfaces:**
- Consumes: Docker Compose stack, bootstrap script, Media Control Windows app.
- Produces: functioning Nyaa source cards and release results in the running local stack.

- [ ] **Step 1: Run all automated checks**

Run Node tests, Flutter analyze/test/build Windows, `docker compose config --quiet`, and `git diff --check`.

- [ ] **Step 2: Apply bootstrap without enabling automatic startup**

Run reconciliation only while the stack is already user-started. Confirm it does not change Compose restart policy.

- [ ] **Step 3: Test as a user in Media Control**

Open Services and verify both Nyaa cards. Search one permitted anime movie and one permitted anime TV episode, open releases, verify source chips, retry behavior, and that another provider still returns when Nyaa.si is blocked.

- [ ] **Step 4: Inspect change impact**

Run GitNexus `detect_changes({scope:'compare',base_ref:'origin/main'})`; review release-search, Services, bootstrap, and download execution flows before any commit.
