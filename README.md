# WSL Media Stack

Docker media stack for WSL2 with qBittorrent, Prowlarr, Radarr, Sonarr, Bazarr, Jellyfin, Jellyseerr, FlareSolverr, Autobrr, PostgreSQL, Redis and a credential-safe gateway.

## Start

From Ubuntu WSL, run:

```bash
cd /mnt/d/path/to/MOVIE
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

The bootstrap creates `/mnt/d/Media`, copies `.env.example` to private `.env`, generates the two database secrets, creates media folders, temporarily starts the stack for configuration, and stops it before returning. Do not commit `.env`.

## Windows installer

Build the unsigned local installer with Administrator access:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-installer.ps1
```

The result is `dist/install.exe`. It installs the app under `C:\Program Files\Media Control`, the stack under `C:\ProgramData\MediaControl\stack`, and creates `uninstall.exe` beside the app. Installation never starts Docker or a media container; the first **Bật server** click performs the idempotent bootstrap.

Warning: the uninstaller requires typing `XOA TOAN BO` and permanently removes the installed stack, its Docker resources, and all content under `D:\Media`. It does not remove Docker Desktop, WSL, Ubuntu, the source repository, or the original installer file.

If Docker Desktop WSL integration is disabled, the bootstrap automatically uses Docker Desktop's Windows CLI and converts `/mnt/d/Media` to `D:/Media` for bind mounts.

The bootstrap completes the local qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr and Jellyfin setup with `admin / media1234`. Prowlarr configures Internet Archive and the explicitly requested YTS indexer (`yts.gg` with `movies-api.accel.li`). Provider credentials and indexers must only be configured for sources you are authorized to use.

Media Control includes server power controls, per-service actions, movie/release search, download queue, manual subtitle selection and a Jellyfin library launcher. The host controller listens only on `127.0.0.1:3210`; the app starts it on demand without starting the media stack.

## Manual startup and cold boot

All media containers use the Docker restart policy `no`. Restarting Windows or
Docker Desktop therefore leaves the media server off. Start it only with the
main **Bật server** button in Media Control or by manually starting containers
in Docker Desktop.

Media Control may start its small loopback host-controller when the app opens.
That controller does not start Docker Desktop or any media container; it only
makes the power buttons available. Its private configuration is stored at
`%LOCALAPPDATA%\MediaControl\config.json`. If controller recovery fails, the app
shows a Vietnamese retry screen instead of a raw socket exception.

The **Tìm phim** page loads **Đang thịnh hành** automatically. Searching still
uses the existing title lookup, and clearing the search restores trending
movies. Trending metadata comes from the local Seerr integration and the
backend keeps only a normalized last-good cache under the media cache folder.

## Flutter Windows client

The client source is in `flutter_app`. On a machine with Flutter Windows desktop support enabled, run `cd flutter_app && flutter create . --platforms=windows && flutter run -d windows`. It displays public gateway health only; service secrets never leave the WSL host.

## Gateway

`GET http://localhost:3000/health` returns readiness. `GET /v1/services` returns public URLs and normalized status without API keys or passwords.

## Subtitle providers

Bazarr remains the automatic subtitle manager. Its `Vietnamese-English`
profile prioritizes Vietnamese and then English, using the free
`yifysubtitles` and `gestdown` providers. OpenSubtitles.com joins the same
concurrent Bazarr search when both local credentials are configured:

```env
OPENSUBTITLES_USERNAME=<free account username>
OPENSUBTITLES_PASSWORD=<free account password>
```

The subtitle tab groups imported TV content by series and season. It displays
`Vietsub x/y` coverage and loads individual episodes only after a season is
selected; episodes missing Vietnamese subtitles are shown first.

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

Samsung TV truy cập qua LAN: http://192.168.100.195:8096.
Firewall giới hạn Private + LocalSubnet, cổng TCP 8096 và UDP 7359.
