# Server Phim

Local media server hosted by the isolated WSL2 distribution `MediaServer`. Docker Engine and application state live on the distro ext4 disk under `D:\WSL\MediaServer`; media and downloads remain easy to access under `D:\Media`.

## Daily operation

Open **Server Phim** from the Desktop or Start Menu. The installed application is at
`D:\WSL\ServerPhimApp` and does not start with Windows. Closing the application does
not stop the server.

The same lifecycle actions remain available from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File D:\WSL\Start-MediaServer.ps1
powershell -ExecutionPolicy Bypass -File D:\WSL\Status-MediaServer.ps1
powershell -ExecutionPolicy Bypass -File D:\WSL\Stop-MediaServer.ps1
powershell -ExecutionPolicy Bypass -File D:\WSL\Update-MediaServer.ps1
```

The server does not start at Windows login. Stopping it terminates only `MediaServer`; it does not alter `Ubuntu`, `PCMClawUbuntu`, or Docker Desktop.

## Local and home-LAN services

Replace `<windows-lan-ip>` with the current Wi-Fi IPv4 address when opening a service from a phone or TV.

| Service | Local URL | Purpose |
| --- | --- | --- |
| Jellyfin | `http://localhost:8096` | Playback and libraries |
| Seerr | `http://localhost:5055` | Movie and series requests |
| Radarr | `http://localhost:7878` | Movies |
| Sonarr | `http://localhost:8989` | TV |
| Lidarr | `http://localhost:8686` | Music |
| Prowlarr | `http://localhost:9696` | Indexers |
| Bazarr | `http://localhost:6767` | Subtitles |
| qBittorrent | `http://localhost:8081` | Torrents |
| SABnzbd | `http://localhost:8085` | Usenet |
| Autobrr | `http://localhost:7474` | Tracker automation |
| Cleanuparr | `http://localhost:11011` | Conservative queue cleanup |
| Wizarr | `http://localhost:5690` | Invitations |

The app backend is `media-control` at `http://127.0.0.1:11444`. It is deliberately
loopback-only, requires a bearer token stored at
`/srv/media-stack/secrets/media-control.token` with mode `0600`, and never exposes
service API keys to Flutter. Original service pages are diagnostic fallbacks only.

Hyper-V Firewall exposes the same ports only to `LocalSubnet` on the Windows Private profile. FlareSolverr stays internal and no router port forwarding is configured.

## Credentials and external accounts

Generated credentials are stored only inside WSL under `/srv/media-stack/.env` and service appdata. Do not copy them into Git or this README. Use the Server Phim app to manage them when available.

Indexers, trackers, Usenet servers, and subtitle providers require legitimate external accounts. Prowlarr, SABnzbd, Autobrr, and Bazarr remain ready but do not invent provider details. For subtitle coverage, start with a supported free provider and optionally add an OpenSubtitles.com account through Bazarr or the app. Vietnamese is preferred and English is the fallback.

The current home-router DNS maps `api.themoviedb.org` to localhost. Seerr now uses
Cloudflare/Google DNS and IPv4-first, but the current Internet connection also resets
TMDB HTTPS by hostname. Discovery will remain empty until that network permits TMDB.
No VPN or reverse proxy was added, as required by the approved design.

See `docs/operations/external-credentials.md` for safe account entry and verification.

## Windows app development and update

```powershell
cd app\server_phim
flutter analyze
flutter test
flutter build windows --release
powershell -ExecutionPolicy Bypass -File ..\..\infra\windows\Install-ServerPhimApp.ps1
```

`D:\WSL\Update-ServerPhimApp.ps1` runs analyze, tests, build and a rollback-capable
install. The C++ ATL optional component is required by `flutter_secure_storage` on
Windows. Tokens are stored through Windows Credential Manager.

## Data layout

- `D:\Media\library\movies`
- `D:\Media\library\tv`
- `D:\Media\library\music`
- `D:\Media\downloads\torrents`
- `D:\Media\downloads\usenet`

All managers and downloaders see the same paths under `/data`, which avoids remote-path mappings and permits hardlink imports when supported.
