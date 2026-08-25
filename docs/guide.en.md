# Media Control Guide

## Installation

Media Control 0.2.0 targets 64-bit Windows 10 or newer. Install WSL2 with the Ubuntu distribution, Docker Desktop, and the Microsoft Visual C++ 2015–2022 x64 runtime. Keep at least 10 GB free on the selected media drive. Flutter Windows support and NSIS 3.x are needed only when building the installer.

Build the unsigned installer from an Administrator PowerShell session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-installer.ps1
```

Run `dist\install.exe` as Administrator. It installs the client in `C:\Program Files\Media Control`, stores the private stack in `C:\ProgramData\MediaControl\stack`, and defaults to `D:\Media`. Installation prepares files, secrets, the loopback controller, and firewall rules but does not start media containers.

For a source checkout, open Ubuntu WSL in the repository and run:

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh --keep-running
```

That command is the first-run path: it starts the stack, waits for required services, calls `auto-configure.ps1 -MediaRoot <Windows path> -FirstRun`, seeds the local cache, completes the Jellyfin wizard, requests the initial Bazarr missing-subtitle search, and leaves the stack running. Omit `--keep-running` to stop it after setup.

For a custom root, set both path forms before first run: for example, `MEDIA_ROOT=/mnt/e/Media` and `MEDIA_ROOT_DOCKER=E:/Media`. The Windows preparation script also accepts `-MediaRoot E:\Media`. Do not move an initialized media root by editing only one variable.

## Workspaces

The Material 3 dark client has two retained workspaces. At 840 px and wider it uses a navigation rail; below 840 px it uses a bottom navigation bar.

- **Content (`Nội dung`)**: Discovery (`Khám phá`), Downloads, Vietsub, and Library (`Thư viện`).
- **System (`Hệ thống`)**: Overview (`Tổng quan`), Services, and Settings (`Cài đặt`).

A page is created on first visit and keeps its filters, selection, and scroll-related state while the user switches destinations. The local host controller may start with the app, but it does not start Docker Desktop or the media stack automatically.

## Workflows

In Discovery, search for movies or series and narrow results by type, year, or library state. Search history keeps up to ten queries in `%LOCALAPPDATA%\MediaControl\search-history.json`; the clear action removes it. Select a result, then use **Find releases**. Media Control prepares Radarr or Sonarr only at that point. For TV, choose a season before requesting season releases, or choose the per-episode path before the episode list is loaded.

Downloads consumes `GET /v1/downloads/events`. The status reads live, reconnecting, or stale data. If SSE drops, the client polls every second while a transfer is active and every five seconds when idle, then returns to SSE after reconnection. Pause, resume, retry, and delete actions have labels; deletion requires confirmation.

Vietsub follows Content → season/episode → source/results. Bazarr is the normal path. YIFY Direct is hidden under the advanced opt-in and remains unavailable unless enabled in the gateway configuration.

Library shows posters, watched/resume state, and opens Jellyfin at `${jellyfinBaseUrl}/web/#/details?id=<jellyfinId>`. `jellyfinBaseUrl` defaults to `http://localhost:8096` and can be changed in the local client configuration.

## Providers

First run and repair reconcile existing resources instead of creating duplicates:

- qBittorrent preferences and the movie/series categories.
- Radarr and Sonarr root folders, qBittorrent clients, and Prowlarr connections.
- Prowlarr applications, tags, the FlareSolverr proxy, and configured indexers.
- Jellyfin networking, movie/series libraries, API token, and Arr notifications.
- Bazarr Arr connections and the Vietnamese/English language profile.

Seerr is optional and may be configured manually; its last-good data can still support discovery fallback. YTS movie and official-TV endpoints are optional public sources controlled by `YTS_MOVIE_API_URL`, `YTS_OFFICIAL_TV_URL`, and `YTS_OFFICIAL_TV_ENABLED`. YIFY Direct is opt-in through `YIFY_DIRECT_ENABLED` and `YIFY_DIRECT_BASE_URL`. OpenSubtitles joins Bazarr only when `OPENSUBTITLES_USERNAME` and `OPENSUBTITLES_PASSWORD` are present. Use only sources and content you are authorized to access.

## Configuration

Private settings live in `.env`; Docker receives the normalized copy in `.env.compose`. Never commit either file. `MEDIA_ROOT` is the WSL path used by provider containers, while `MEDIA_ROOT_DOCKER` is the Windows/Docker Desktop bind path used by the gateway. They must identify the same directory.

Required local values include `PUID`, `PGID`, `TZ`, the local admin credentials, host-controller token, subtitle token secret, TV download token secret, WSL distribution, and project path. The installer replaces placeholders with generated secrets on a new installation and preserves them on update.

Optional values cover OpenSubtitles, a pre-existing Jellyfin API key, YIFY Direct, YTS endpoints, and the official-TV toggle. The default service account is convenient for a loopback-only PC; do not expose provider ports to the Internet with default credentials. The gateway is bound to `127.0.0.1:3000`, and the host controller uses `127.0.0.1:3210` with its private token.

## Docker

The Compose project runs one Node gateway with qBittorrent, Prowlarr, Radarr, Sonarr, Bazarr, Jellyfin, optional Seerr, and FlareSolverr. Image tags remain those declared in `docker-compose.yml`; normal setup does not pull or upgrade providers explicitly.

Start or reconcile the whole stack from the project directory:

```bash
docker compose --env-file .env.compose up -d --build --remove-orphans
```

Inspect or stop it without deleting data:

```bash
docker compose --env-file .env.compose ps
docker compose --env-file .env.compose stop
```

Do not use `docker compose down -v` or `docker volume rm` during installation, update, repair, or normal operation. Legacy PostgreSQL and Redis volumes are deliberately left untouched even though those services are no longer in Compose. The repair workflow restores the previous stopped/running state.

## Troubleshooting

Run `docker compose --env-file .env.compose config` first to catch path or environment mistakes, then `docker compose --env-file .env.compose ps` and `docker compose --env-file .env.compose logs <service>`. If Ubuntu cannot call `docker`, enable Docker Desktop WSL integration; bootstrap can also use Docker Desktop's Windows CLI when it is installed in its standard location.

If the app cannot use its power controls, restart the app and verify `%LOCALAPPDATA%\MediaControl\config.json` points to the installed controller launcher. If the gateway is ready but a source fails, the UI may show a partial result or `provider_unavailable`; check only that provider instead of recreating the stack.

Test the gateway and download stream locally:

```bash
curl http://localhost:3000/health
curl -N http://localhost:3000/v1/downloads/events
```

For Jellyfin links from another machine, set `jellyfinBaseUrl` to the reachable LAN URL. Keep the gateway and host controller loopback-only.

## Repair

From Ubuntu WSL in the installed stack or source repository, run:

```bash
./scripts/bootstrap.sh --repair
```

Repair starts the services only as needed, performs GET → compare → update/create reconciliation, and restores a previously stopped stack. It does not run the Jellyfin wizard, cache seed, or Bazarr search-missing batch. Running repair twice should leave the canonical configuration unchanged and should not add duplicate clients, applications, tags, proxies, libraries, or profiles.

When the stack is already running, an operator may run this command directly from PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\auto-configure.ps1 -MediaRoot 'D:\Media'
```

Do not add `-FirstRun` for routine repair. Installer updates request the same repair path after a completed first run.

## Safe uninstall

Stopping the stack or repairing it never removes media or Docker volumes. To keep data, use `docker compose --env-file .env.compose stop`, back up `.env` plus the media root, and do not run the uninstaller.

The packaged uninstaller is intentionally destructive. It requires the exact text `XOA TOAN BO`, verifies the `.media-control-root` ownership marker, removes this installation's containers and unused images, removes the two retained legacy database volumes, and permanently deletes the selected media root. Back up every movie, series, download, subtitle, configuration, and secret before confirming. Never substitute a manual `down -v` or `volume rm`; those commands bypass the ownership checks.
