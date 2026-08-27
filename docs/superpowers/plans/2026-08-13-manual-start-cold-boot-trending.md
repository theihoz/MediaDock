# Manual Start, Cold-Boot Recovery, and Trending Movies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the media stack off until a manual Start action, recover the loopback host-controller automatically when Media Control opens, and show trending movies before the user searches.

**Architecture:** Docker Compose uses a no-restart policy and the host-controller exposes explicit lifecycle commands only. A Flutter controller bootstrapper starts only the local Node controller and gates host calls behind bounded readiness checks. The backend reads the local Seerr API key from its mounted config, normalizes Seerr discovery results, and persists a bounded last-good trending cache for Flutter.

**Tech Stack:** Docker Compose v2, Node.js ES modules and `node:test`, PowerShell, Flutter/Dart, package `http`, Seerr REST API, GitNexus.

## Global Constraints

- Opening Media Control must never start Docker Desktop or a media container.
- Docker daemon or Windows restart must leave the media stack stopped.
- The host-controller listens only on `127.0.0.1` and requires its bearer token.
- Raw `SocketException`, ports, credentials, and upstream response bodies never appear in the UI.
- Trending discovery adds no paid provider and sends no internal API key to Flutter.
- Explicit title search, release selection, downloads, subtitles, library, and service controls remain available.
- Runtime `.env`, `.env.compose`, Seerr configuration, caches, and GitNexus index remain untracked.

---

### Task 1: Enforce Manual Docker Lifecycle

**Files:**
- Create: `backend/test/compose-policy.test.mjs`
- Modify: `docker-compose.yml`
- Modify: `host-controller/src/controller.mjs`
- Modify: `host-controller/src/server.mjs`
- Modify: `host-controller/test/controller.test.mjs`

**Interfaces:**
- Produces: `wholeStackCommands(action: string): string[][]`
- Produces: `isMissingStackError(error: unknown): boolean`
- Preserves: `composeArgs(action, service)` for individual service actions.

- [ ] **Step 1: Write failing restart-policy and lifecycle tests**

```js
// backend/test/compose-policy.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('all compose services require manual restart', () => {
  const compose = fs.readFileSync(new URL('../../docker-compose.yml', import.meta.url), 'utf8');
  assert.doesNotMatch(compose, /restart:\s*unless-stopped/);
  assert.equal((compose.match(/restart:\s*["']?no["']?/g) ?? []).length >= 1, true);
});
```

```js
// append to host-controller/test/controller.test.mjs
import { wholeStackCommands } from '../src/controller.mjs';

test('whole stack start prefers existing stopped containers', () => {
  assert.deepEqual(wholeStackCommands('start'), [
    ['compose', 'start'],
    ['compose', 'up', '-d'],
  ]);
  assert.deepEqual(wholeStackCommands('stop'), [['compose', 'stop']]);
});
```

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test backend/test/compose-policy.test.mjs host-controller/test/controller.test.mjs`

Expected: FAIL because Compose contains `unless-stopped` and `wholeStackCommands` is not exported.

- [ ] **Step 3: Implement the minimal lifecycle policy**

Set the shared anchor and PostgreSQL, Redis, and API overrides to:

```yaml
restart: "no"
```

Add to `host-controller/src/controller.mjs`:

```js
export function wholeStackCommands(action) {
  if (action === 'start') return [['compose', 'start'], ['compose', 'up', '-d']];
  if (action === 'stop') return [['compose', 'stop']];
  if (action === 'restart') return [['compose', 'restart']];
  throw new Error(`Unsupported action: ${action}`);
}
```

Update the whole-stack handler so Start runs `compose start` and invokes
`compose up -d` only when Start reports that no containers exist. It must not
fall back for authentication, daemon, or configuration errors.

- [ ] **Step 4: Run focused and existing controller tests**

Run: `node --test backend/test/compose-policy.test.mjs host-controller/test/controller.test.mjs`

Expected: PASS.

- [ ] **Step 5: Validate rendered Compose configuration**

Run: `docker compose --env-file .env.compose config --quiet`

Expected: exit 0 and every rendered service has restart policy `no`.

- [ ] **Step 6: Commit**

```powershell
git add docker-compose.yml backend/test/compose-policy.test.mjs host-controller/src/controller.mjs host-controller/src/server.mjs host-controller/test/controller.test.mjs
git commit -m "fix: require manual media stack startup"
```

---

### Task 2: Recover the Local Controller After Cold Boot

**Files:**
- Create: `flutter_app/lib/controller_bootstrap.dart`
- Create: `flutter_app/test/controller_bootstrap_test.dart`
- Create: `scripts/install-host-controller.ps1`
- Modify: `flutter_app/lib/main.dart`
- Modify: `flutter_app/test/widget_test.dart`
- Modify: `scripts/start-host-controller.ps1`

**Interfaces:**
- Produces: `ControllerBootstrapper.ensureReady(): Future<ControllerStartupResult>`
- Produces: `ControllerStartupResult.ready` and `.failed`
- Extends: `LocalConfig.controllerLauncher` with a local configuration value.

- [ ] **Step 1: Write failing unit tests for bounded recovery**

```dart
test('launches the controller once and retries without starting the server', () async {
  var probes = 0;
  var launches = 0;
  final bootstrapper = ControllerBootstrapper(
    probe: () async => ++probes >= 3,
    launch: () async => launches++,
    delay: (_) async {},
    attempts: 4,
  );

  expect(await bootstrapper.ensureReady(), ControllerStartupResult.ready);
  expect(launches, 1);
  expect(probes, 3);
});

test('returns a friendly failed state after bounded retries', () async {
  final bootstrapper = ControllerBootstrapper(
    probe: () async => false,
    launch: () async {},
    delay: (_) async {},
    attempts: 2,
  );
  expect(await bootstrapper.ensureReady(), ControllerStartupResult.failed);
});
```

- [ ] **Step 2: Run tests and verify RED**

Run: `cd flutter_app; flutter test test/controller_bootstrap_test.dart`

Expected: FAIL because `controller_bootstrap.dart` and its types do not exist.

- [ ] **Step 3: Implement the controller bootstrapper**

Implement a single-flight `ensureReady()` that:

1. probes `/host/status` with a two-second timeout;
2. launches `powershell.exe -WindowStyle Hidden -File <controllerLauncher>` once;
3. retries four times with `250ms`, `500ms`, `1000ms`, and `2000ms` delays;
4. returns a normalized enum instead of throwing network exceptions.

The launcher must execute only `scripts/start-host-controller.ps1`; it must not
invoke `docker`, `docker compose`, Docker Desktop, or a stack Start endpoint.

- [ ] **Step 4: Gate Flutter host access and normalize UI errors**

Extend `LocalConfig`:

```dart
final String gateway, controller, token, controllerLauncher;
```

Add a controller state banner to `MediaShell`. While recovery runs, show
`Đang kết nối bộ điều khiển…`. On terminal failure show
`Không thể khởi động bộ điều khiển cục bộ` with `Thử lại` and `Cài đặt`.
Map `SocketException` and `TimeoutException` in `showError` to a Vietnamese
message and never interpolate the raw exception.

- [ ] **Step 5: Create the idempotent local installer**

`scripts/install-host-controller.ps1` must create
`%LOCALAPPDATA%\MediaControl\config.json` atomically with:

```json
{
  "gateway": "http://localhost:3000",
  "controller": "http://127.0.0.1:3210",
  "token": "<HOST_CONTROLLER_TOKEN from private .env>",
  "controllerLauncher": "<absolute path to scripts/start-host-controller.ps1>"
}
```

It must not create a Scheduled Task, Startup shortcut, service, or Run registry
entry. `start-host-controller.ps1` must use a single-instance mutex or port
probe so repeated app launches do not create duplicate Node processes.

- [ ] **Step 6: Add widget tests for cold-boot states**

Inject a fake bootstrapper into `MediaShell` and assert:

```dart
expect(find.text('Đang kết nối bộ điều khiển…'), findsOneWidget);
expect(find.textContaining('SocketException'), findsNothing);
expect(find.text('Không thể khởi động bộ điều khiển cục bộ'), findsOneWidget);
expect(find.text('Thử lại'), findsOneWidget);
```

- [ ] **Step 7: Run Flutter verification**

Run: `cd flutter_app; flutter analyze; flutter test`

Expected: no analyze issues and all tests pass.

- [ ] **Step 8: Commit**

```powershell
git add flutter_app/lib flutter_app/test scripts/install-host-controller.ps1 scripts/start-host-controller.ps1
git commit -m "feat: recover local controller on app startup"
```

---

### Task 3: Add Cached Seerr Trending Discovery

**Files:**
- Create: `backend/src/trending-movies.mjs`
- Create: `backend/test/trending-movies.test.mjs`
- Modify: `backend/src/media-clients.mjs`
- Modify: `backend/src/server.mjs`
- Modify: `docker-compose.yml`

**Interfaces:**
- Produces: `normalizeTrendingMovie(value): PublicMovie`
- Produces: `TrendingMovies.get(): Promise<{items: PublicMovie[], source: string, stale: boolean}>`
- Adds: `GET /v1/movies/trending`

- [ ] **Step 1: Write failing normalization and cache tests**

```js
test('normalizes Seerr discovery without exposing provider fields', () => {
  assert.deepEqual(normalizeTrendingMovie({
    id: 603, title: 'The Matrix', releaseDate: '1999-03-30',
    overview: 'A hacker discovers the truth.', posterPath: '/poster.jpg',
    genreIds: [28], mediaInfo: { id: 7 }, voteAverage: 8.2,
  }), {
    tmdbId: 603, title: 'The Matrix', year: 1999,
    overview: 'A hacker discovers the truth.',
    poster: 'https://image.tmdb.org/t/p/w500/poster.jpg',
    runtime: null, genres: [], inLibrary: true, rating: 8.2,
  });
});

test('returns last-good cache when Seerr is unavailable', async () => {
  const store = new MemoryTrendingStore([{ tmdbId: 603, title: 'Cached' }]);
  const trending = new TrendingMovies({ fetchPage: async () => { throw new Error('offline'); }, store });
  assert.deepEqual(await trending.get(), {
    items: [{ tmdbId: 603, title: 'Cached' }], source: 'cache', stale: true,
  });
});
```

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test backend/test/trending-movies.test.mjs`

Expected: FAIL because the trending module does not exist.

- [ ] **Step 3: Implement Seerr discovery and bounded JSON cache**

Read `main.apiKey` from `/service-config/seerr.json`. Request:

```text
GET http://seerr:5055/api/v1/discover/movies?page=1&sortBy=popularity.desc
X-Api-Key: <local key>
```

Normalize at most 40 results and write only normalized public fields to
`/data/cache/trending.json` through a temporary file plus atomic rename. Cache
read errors return an empty result; upstream error bodies and API keys are not
included in returned errors or logs.

- [ ] **Step 4: Wire the endpoint and mounts**

Add to the API service:

```yaml
environment:
  SEERR_CONFIG: /service-config/seerr.json
  TRENDING_CACHE: /data/cache/trending.json
volumes:
  - "${MEDIA_ROOT}/config/seerr/settings.json:/service-config/seerr.json:ro"
  - "${MEDIA_ROOT}/cache:/data/cache"
```

Return HTTP 200 with the normalized envelope for both live and cached results.
When neither exists, return `{ "items": [], "source": "unavailable", "stale": false }`.

- [ ] **Step 5: Run backend and Compose tests**

Run: `node --test backend/test/*.test.mjs`

Run: `docker compose --env-file .env.compose config --quiet`

Expected: all Node tests pass and Compose renders successfully.

- [ ] **Step 6: Commit**

```powershell
git add backend/src backend/test docker-compose.yml
git commit -m "feat: add cached trending movie discovery"
```

---

### Task 4: Show Trending Movies While Retaining Search

**Files:**
- Modify: `flutter_app/lib/main.dart`
- Modify: `flutter_app/test/widget_test.dart`

**Interfaces:**
- Consumes: `GET /v1/movies/trending` envelope from Task 3.
- Preserves: `/v1/movies/search?q=...` and movie release selection.

- [ ] **Step 1: Write failing trending/search widget tests**

Extend the fake API so `/v1/movies/trending` returns The Matrix and search for
`Dune` returns Dune. Add tests asserting:

```dart
await tester.pumpWidget(MaterialApp(home: Scaffold(body: MovieSearchPage(api: api))));
await tester.pumpAndSettle();
expect(find.text('Đang thịnh hành'), findsOneWidget);
expect(find.textContaining('The Matrix'), findsOneWidget);

await tester.enterText(find.byType(TextField), 'Dune');
await tester.tap(find.text('Tìm'));
await tester.pumpAndSettle();
expect(find.textContaining('Dune'), findsOneWidget);

await tester.enterText(find.byType(TextField), '');
await tester.testTextInput.receiveAction(TextInputAction.search);
await tester.pumpAndSettle();
expect(find.textContaining('The Matrix'), findsOneWidget);
```

- [ ] **Step 2: Run test and verify RED**

Run: `cd flutter_app; flutter test test/widget_test.dart`

Expected: FAIL because the page does not request trending movies or render its heading.

- [ ] **Step 3: Implement the responsive trending grid**

Call `loadTrending()` from `initState`. Track `displayMode` as trending or
search without creating a second detail flow. Render `GridView.builder` with a
maximum card width near 220px, poster aspect ratio 2:3, title, year, and rating.
Use the existing `loadReleases` callback for both trending and searched cards.

Submitting trimmed empty text calls `loadTrending()`. Non-empty text calls the
existing search endpoint. Add a clear suffix button that clears the controller
and restores trending results. An unavailable empty response shows
`Chưa tải được phim thịnh hành` and a Refresh button.

- [ ] **Step 4: Prevent eager offline page failures**

Replace the eager `IndexedStack` page list with lazy page construction for the
selected destination. This prevents Downloads, Subtitles, Library, and Services
from all issuing network calls as soon as the app opens. Preserve the selected
navigation index.

- [ ] **Step 5: Run Flutter tests and analyze**

Run: `cd flutter_app; flutter analyze; flutter test`

Expected: no analyze issues and all widget/unit tests pass.

- [ ] **Step 6: Commit**

```powershell
git add flutter_app/lib/main.dart flutter_app/test/widget_test.dart
git commit -m "feat: browse trending movies before search"
```

---

### Task 5: Leave Bootstrap Stopped and Verify the Complete Story

**Files:**
- Create: `scripts/test-manual-start.ps1`
- Modify: `scripts/bootstrap.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: manual Compose policy, controller launcher, and trending endpoint.
- Produces: a repeatable operator verification command.

- [ ] **Step 1: Write the failing static bootstrap check**

`scripts/test-manual-start.ps1` reads `scripts/bootstrap.sh` and asserts that
the final successful path contains `compose ... stop`, that the final message
says the stack is stopped, and that no installer creates Scheduled Task,
Startup shortcut, Windows service, or Run registry entries.

- [ ] **Step 2: Run the test and verify RED**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-manual-start.ps1`

Expected: FAIL because bootstrap currently exits with the stack running.

- [ ] **Step 3: Stop the stack at the end of successful bootstrap**

After configuration completes, run:

```bash
"${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" stop
```

Print exactly:

```text
Setup complete. Media stack is stopped. Start it from Media Control or Docker Desktop.
```

Do not stop containers on a failed bootstrap path where logs are needed for diagnosis.

- [ ] **Step 4: Document the operator behavior**

Update README with the cold-boot sequence, the fact that the controller may
start locally while media stays off, manual Docker/app Start options, trending
cache behavior, and the private config location.

- [ ] **Step 5: Run full verification**

```powershell
node --test backend/test/*.test.mjs
node --test host-controller/test/*.test.mjs
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-manual-start.ps1
docker compose --env-file .env.compose config --quiet
Push-Location flutter_app
flutter analyze
flutter test
flutter build windows --release
Pop-Location
git diff --check
npx --yes gitnexus@latest detect-changes --scope all --base-ref main --limit 200
```

Expected: all commands exit 0; no raw credentials appear; GitNexus reports only
the expected lifecycle, controller startup, discovery, and movie-page flows.

- [ ] **Step 6: Perform a local cold-boot simulation**

1. Stop the Compose stack and host-controller.
2. Open Media Control.
3. Verify the host-controller becomes reachable on loopback.
4. Verify `docker compose ps` reports no running media services.
5. Press Start in Media Control and verify the stack reaches ready/degraded
   without a raw socket exception.
6. Open Tìm phim and verify trending cards appear; search for a title and clear
   the query to restore trending cards.

- [ ] **Step 7: Commit**

```powershell
git add scripts/bootstrap.sh scripts/test-manual-start.ps1 README.md
git commit -m "docs: finalize manual startup workflow"
```

- [ ] **Step 8: Refresh GitNexus and push the branch**

```powershell
npx --yes gitnexus@latest analyze
git status -sb
git push
```
