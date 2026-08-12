# WSL Media Stack

Docker media stack for WSL2 with qBittorrent, Prowlarr, Radarr, Sonarr, Bazarr, Jellyfin, Jellyseerr, FlareSolverr, Autobrr, PostgreSQL, Redis and a credential-safe gateway.

## Start

From Ubuntu WSL, run:

```bash
cd /mnt/d/path/to/MOVIE
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

The bootstrap creates `/mnt/d/Media`, copies `.env.example` to private `.env`, generates the two database secrets, creates media folders, then starts the stack. Do not commit `.env`.

If Docker Desktop WSL integration is disabled, the bootstrap automatically uses Docker Desktop's Windows CLI and converts `/mnt/d/Media` to `D:/Media` for bind mounts.

The bootstrap completes the local qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr and Jellyfin setup with `admin / media1234`. Prowlarr configures Internet Archive and the explicitly requested YTS indexer (`yts.gg` with `movies-api.accel.li`). Provider credentials and indexers must only be configured for sources you are authorized to use.

Media Control includes server power controls, per-service actions, movie/release search, download queue, manual subtitle selection and a Jellyfin library launcher. The host controller listens only on `127.0.0.1:3210` and starts with Windows.

## Flutter Windows client

The client source is in `flutter_app`. On a machine with Flutter Windows desktop support enabled, run `cd flutter_app && flutter create . --platforms=windows && flutter run -d windows`. It displays public gateway health only; service secrets never leave the WSL host.

## Gateway

`GET http://localhost:3000/health` returns readiness. `GET /v1/services` returns public URLs and normalized status without API keys or passwords.

## Subtitle providers

Bazarr remains the automatic subtitle manager. Its `Vietnamese-English`
profile prioritizes Vietnamese and then English, using the free
`yifysubtitles` and `gestdown` providers.

Media Control also offers an optional manual `YIFY Direct` fallback. The
backend matches an existing library movie by IMDb ID, returns signed five-minute
download tokens, limits file size, validates archive entries, and refreshes
Bazarr and Jellyfin after installation. Flutter never receives raw provider
URLs or destination paths. If the public provider requires a CAPTCHA or browser
challenge, the backend reports `provider_unavailable` and does not bypass it.

```env
YIFY_DIRECT_ENABLED=true
YIFY_DIRECT_BASE_URL=https://yifysubtitles.ch
SUBTITLE_TOKEN_SECRET=<random local secret>
```

Only use media and subtitles you are authorized to access.

## GitNexus

The repository is indexed locally with GitNexus. The generated knowledge graph
is intentionally excluded from Git, while `AGENTS.md`, `CLAUDE.md`, and the
GitNexus skills are versioned so coding agents receive the project context.

```powershell
npx --yes gitnexus@latest status
npx --yes gitnexus@latest analyze
npx --yes gitnexus@latest setup -c codex
```

Auto-config supports qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr, and
Jellyfin. The default local account is `admin / media1234`; do not expose these
services directly to the Internet with that password.
