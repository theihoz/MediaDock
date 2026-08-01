# WSL Media Server Design

## Goal

Create a third, independent Ubuntu 24.04 LTS WSL2 distribution named `MediaServer`. Its virtual disk, Docker Engine, Compose project, and application state live under `D:\WSL\MediaServer`. Media and download files live under `D:\Media` so they remain easy to manage from Windows Explorer. The two existing distributions (`Ubuntu` and `PCMClawUbuntu`) and Docker Desktop remain unchanged.

## Architecture

- Install the distro directly with WSL's `--location` support; do not clone or move an existing distro.
- Enable systemd in `MediaServer` and install Docker Engine plus the Compose plugin from Docker's official Ubuntu repository. Docker Desktop is not used by this stack.
- Keep the existing global WSL limits of 16 processors and 8 GB RAM. Add `networkingMode=mirrored` and keep the WSL firewall enabled so home-LAN devices can reach services through the Windows host address.
- Do not start the distro at Windows sign-in. The user starts and stops it with PowerShell helper scripts under `D:\WSL`.
- Use one private Compose network for service-to-service traffic. Publish only web UIs and required playback/download ports to the host. Windows/Hyper-V firewall rules allow inbound access only on the Private network profile; no router port-forwarding, public exposure, HTTPS proxy, or VPN is configured.
- Pass the NVIDIA RTX 4050 into Jellyfin with NVIDIA Container Toolkit and use NVENC/NVDEC for transcoding. Direct play remains preferred. The target is two simultaneous 1080p/4K clients on the home Wi-Fi.

## Services and Integration

The Compose project includes Jellyfin, Seerr (the maintained successor to Jellyseerr), Radarr, Sonarr, Lidarr, Prowlarr, Bazarr, qBittorrent, SABnzbd, Autobrr, FlareSolverr, Cleanuparr, and Wizarr. Stable production images are used and container logs are rotated.

- Jellyfin is the playback server; Seerr sends movie and series requests to Radarr and Sonarr; Wizarr manages Jellyfin invitations.
- Prowlarr synchronizes configured indexers to Radarr, Sonarr, and Lidarr. FlareSolverr is available only for a compatible indexer that needs it.
- Radarr, Sonarr, and Lidarr use qBittorrent and SABnzbd as download clients. Categories keep movies, TV, and music separate.
- Autobrr is connected to qBittorrent and the Arr services. Cleanuparr is connected to the Arr services and qBittorrent, with conservative cleanup defaults that do not delete imported library media.
- External Usenet providers, indexers, trackers, and IRC credentials cannot be invented. Their services are installed and internally wired, then left ready for the user to add legitimate account details.
- qBittorrent's host web port is `8081` because Windows port `8080` is already occupied by Java. Other services use their standard host ports unless a validation check finds an actual conflict before deployment.

## Storage and Identity

Application databases and configuration live on the distro's ext4 filesystem under `/srv/media-stack/appdata/<service>`. Compose files and operator scripts live under `/srv/media-stack`. All compatible containers run as the same non-root media user (`UID=1000`, `GID=1000`) with timezone `Asia/Ho_Chi_Minh`.

The Windows data tree is mounted consistently as `/data` in every downloader and library manager:

```text
D:\Media\downloads\torrents\movies
D:\Media\downloads\torrents\tv
D:\Media\downloads\torrents\music
D:\Media\downloads\usenet\incomplete
D:\Media\downloads\usenet\complete\movies
D:\Media\downloads\usenet\complete\tv
D:\Media\downloads\usenet\complete\music
D:\Media\library\movies
D:\Media\library\tv
D:\Media\library\music
```

The shared `/data` mount preserves consistent paths and permits hardlink imports when DrvFS supports them. Deployment must verify hardlink behavior rather than assume it; if unsupported, imports fall back to copy without changing the public paths.

Generated service credentials are unique and stored only inside the distro in a mode-`0600` operator file. `D:\Media\SERVER-README.txt` contains service URLs and basic commands but no passwords or API secrets.

## Operations and Failure Handling

- `D:\WSL\Start-MediaServer.ps1` starts the distro, waits for Docker, and runs `docker compose up -d` idempotently.
- `D:\WSL\Stop-MediaServer.ps1` stops the Compose services cleanly and terminates only `MediaServer`.
- `D:\WSL\Status-MediaServer.ps1` reports distro, Docker, container health, storage, and service URLs.
- `D:\WSL\Update-MediaServer.ps1` performs an explicit image pull and controlled Compose recreation; there is no unattended image updater.
- Containers use `restart: unless-stopped` and health checks where the upstream image exposes a meaningful check. Compose start order uses health/readiness rather than arbitrary sleeps where possible.
- A failed optional integration does not hide core failures. Jellyfin, the three Arr managers, Prowlarr, and at least one download client must be healthy before the deployment is considered usable. NVENC failure is diagnosed separately, with direct play/software fallback available while GPU setup is corrected.

## Acceptance Criteria

- `wsl --list --verbose` shows `MediaServer` as WSL2 and its registered base path resolves under `D:\WSL\MediaServer`; existing distro registration and default selection are unchanged.
- Docker commands inside `MediaServer` use the distro-local Docker Engine, and all 13 requested services are created with persistent state on the intended paths.
- A file created in `D:\Media` is visible at the expected `/data` path in relevant containers; read/write permissions and a hardlink probe are recorded.
- Internal DNS and API checks prove the declared service connections. External-provider-dependent integrations are clearly reported as awaiting user credentials.
- A phone or TV on the home Wi-Fi can open Jellyfin and Seerr through the Windows host's LAN address, while the services are not deliberately exposed beyond the Private LAN profile.
- A forced 4K-to-1080p Jellyfin playback shows an active NVIDIA transcoding process and remains playable; direct play is also verified.
- Stopping and starting through the helper scripts restores healthy containers without touching `Ubuntu`, `PCMClawUbuntu`, or Docker Desktop.

## Explicit Non-Goals

- No migration or deletion of existing WSL distributions or Docker Desktop data.
- No automatic Windows-login startup, remote Internet access, reverse proxy, TLS certificate, VPN, router port-forwarding, or acquisition of third-party media/indexer accounts.
- No guarantee that every provider-specific integration can be completed without the user's credentials.
