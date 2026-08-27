# Manual Start, Cold-Boot Recovery, and Trending Movies Design

## Goal

Make Media Control reliable after a Windows restart while preserving a strict
manual-start policy for the media server. The movie search page must also show
trending movies before the user enters a search term.

## Scope

This change covers three connected behaviors:

1. Docker media containers never start merely because Windows or Docker Desktop
   starts.
2. The Flutter application can recover its local host-controller after a cold
   boot without exposing raw connection exceptions.
3. The movie search page loads a browsable trending catalogue while retaining
   explicit title search and the existing release-selection flow.

It does not expose the controller to the LAN, start the media stack when the
application opens, or add a new paid metadata provider.

## Manual Server Lifecycle

All Compose services use `restart: "no"`. A Docker daemon restart therefore
leaves the media stack stopped. The supported ways to start it are:

- the main Start button in Media Control;
- a service Start action in Media Control; or
- a manual Start action in Docker Desktop.

The host-controller may run in the background because it is only a loopback
control plane. Starting the controller must not start Docker Desktop or any
media container.

The whole-stack Start action first tries `docker compose start`. If the
containers do not exist yet, it falls back to `docker compose up -d`. Stop uses
`docker compose stop`, preserving containers and their configuration for the
next manual start.

Bootstrap may temporarily start services to finish first-time configuration.
Before it exits successfully, it stops the stack and reports that the user must
start it from Docker Desktop or Media Control.

## Cold-Boot Controller Recovery

Flutter owns an application-level controller bootstrapper. On application
startup it probes `GET /host/status` with a short timeout. A connection-refused
or timeout result triggers the local PowerShell controller launcher in a hidden
process. Flutter then retries health checks with bounded backoff.

The launcher path is resolved from the local Media Control configuration. The
configuration gains an optional `controllerLauncher` value and retains a safe
project-relative/default fallback for the local installation. The token remains
local and is not printed in UI or logs.

During recovery, the app shows a non-blocking Vietnamese status such as
`Đang kết nối bộ điều khiển…`. It never renders `SocketException`, port numbers,
or a stack trace to the user. If recovery fails, the app shows `Không thể khởi
động bộ điều khiển cục bộ` with Retry and Open settings actions. Other pages
remain usable where possible.

Controller recovery starts only the Node host-controller. Docker Desktop and
the media stack stay off until the user presses Start.

## Trending Movie Discovery

The backend adds `GET /v1/movies/trending`. Results use the same public movie
shape already consumed by Flutter:

- `tmdbId`
- `title`
- `year`
- `overview`
- `poster`
- `runtime`
- `genres`
- `inLibrary`

The discovery client uses the existing local media-stack discovery service when
available. It does not send internal service API keys to Flutter. The backend
stores the last successful normalized result in a bounded local cache so a
temporary provider failure does not erase a previously loaded catalogue.

If no live or cached discovery data exists, the API returns an empty list plus
a normalized availability state rather than propagating provider HTML, network
details, or credentials. Search through `GET /v1/movies/search?q=...` remains
unchanged.

The Flutter movie page loads trending movies in `initState`. With an empty
search field it shows a responsive poster grid titled `Đang thịnh hành`. A
submitted non-empty query replaces the grid with search results. Clearing the
query restores trending results without requiring an application restart.
Selecting either a trending or searched movie opens the same detail and
interactive release-selection view.

## Error Handling

- Controller connection failures are mapped to friendly local states.
- A controller launch is deduplicated so concurrent page requests cannot spawn
  multiple Node processes.
- Controller retries are bounded; the UI always leaves its loading state.
- Trending-provider failures do not affect explicit title search, downloads,
  subtitles, or the library.
- Empty trending data is displayed as a recoverable empty state with Refresh.
- Docker-not-running is displayed as `Server đang tắt`, not as an application
  failure.

## Testing

Tests are written before production changes and cover:

1. Compose contains no automatic restart policy.
2. Host-controller construction does not execute a Compose start command.
3. Whole-stack Start prefers `compose start` and falls back to `up -d` only for
   a missing stack.
4. Flutter detects a refused controller connection, launches it once, retries,
   and leaves the media stack stopped.
5. Flutter converts terminal controller failure into a Vietnamese recoverable
   state without exposing `SocketException`.
6. The backend normalizes trending results, uses a last-good cache, and redacts
   upstream errors.
7. The movie page loads trending items initially, retains explicit search, and
   restores trending items when the query is cleared.
8. Existing release selection, download, subtitle, service-control, Flutter
   analyze, Flutter tests, Node tests, and Compose validation remain green.

## Acceptance Criteria

- Restarting Windows and opening Media Control does not display a raw socket
  exception.
- Opening Media Control may start the loopback controller but does not start
  Docker Desktop or any media container.
- Restarting Docker Desktop does not automatically start media containers.
- Pressing Start in Media Control starts the existing stack and reconnects the
  gateway.
- The movie page immediately offers trending movies and still searches by
  title.
- Secrets remain absent from Flutter responses, logs, Git, and user-facing
  errors.
