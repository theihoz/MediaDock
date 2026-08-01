# Server Phim Windows App Design

## Goal

Build a local-only Flutter Windows application for the owner of this PC. The app provides one coherent interface for operating the existing `MediaServer` WSL distribution, requesting and managing media, monitoring downloads, automating Vietnamese subtitles with English fallback, and administering the media stack without routinely opening individual service websites.

## Architecture

The Windows client is a Flutter desktop application installed at `D:\WSL\ServerPhimApp`. It does not start at Windows sign-in and does not expose an administrative UI to the LAN. When `MediaServer` is stopped, the application offers an explicit Start button and invokes the existing PowerShell lifecycle scripts. Closing the application does not stop the server.

A Python/FastAPI container named `media-control` runs inside the existing Docker Compose project. It binds only to `127.0.0.1:11444` and exposes a stable `/v1` API plus Server-Sent Events. Service adapters isolate Jellyfin, Seerr, Radarr, Sonarr, Lidarr, Prowlarr, Bazarr, qBittorrent, SABnzbd, Autobrr, Cleanuparr, and Wizarr API differences. FlareSolverr is managed through its Prowlarr integration.

The backend owns service API keys and generated credentials. A control token is stored mode `0600` inside WSL; Flutter retrieves it through a local WSL helper and stores it with Windows Credential Manager. Secrets never enter Git, Flutter source, normal logs, or diagnostic responses.

## User Experience

The application uses six primary destinations:

- Overview: WSL, Docker, GPU, storage, service health, and lifecycle controls.
- Discover: Seerr-backed search and one-click requests, defaulting to 1080p with a per-item 4K option.
- Library: Movies, TV, and Music with monitoring, refresh, scan, and guarded deletion.
- Downloads: a unified qBittorrent and SABnzbd queue with pause, resume, retry, and cancel.
- Subtitles: Vietnamese-first status and search, English fallback, Bazarr synchronization, and provider configuration.
- Administration: indexers, download clients, quality profiles, root folders, providers, and the advanced service integrations.

Original service UIs remain available only as diagnostic escape hatches. The application shows state internally and does not create Windows toast notifications.

## Public API

The backend exposes authenticated loopback-only endpoints under `/v1`: status, services, storage, events, discovery, requests, library, downloads, subtitles, administration, and operations. Common models are `MediaItem`, `MediaRequest`, `DownloadJob`, `SubtitleState`, `ServiceHealth`, `StorageStatus`, and `OperationResult`.

Mutations accept idempotency keys. Destructive media deletion, download-data deletion, and cleanup require a short-lived confirmation token obtained from a separate confirmation endpoint. Errors identify the affected service without leaking passwords, cookies, tokens, or API keys. A failed optional service degrades only its module.

## Subtitle Policy

Bazarr connects to Radarr and Sonarr. Vietnamese is preferred; English is retained as a fallback when Vietnamese is unavailable. Existing suitable Vietnamese subtitles are not overwritten merely because a new result appears. Providers that do not require an account are preferred, while the app also offers local forms for legitimate provider credentials.

## Operations and Packaging

The app uses the existing Start, Stop, Status, and Update PowerShell scripts. Start remains manual. The release is copied to `D:\WSL\ServerPhimApp` with Desktop and Start Menu shortcuts and no login autostart. Updates are explicit, health-checked, and offer rollback when a core component fails.

## Acceptance Criteria

- The app can start a stopped `MediaServer` and show a healthy dashboard without starting other WSL distributions.
- One-click requests use 1080p by default; a 4K selection maps to the configured UHD profile.
- Download progress and controls work across qBittorrent and SABnzbd.
- Subtitle state represents Vietnamese preference and English fallback correctly.
- Deep administration is available without exposing secrets or requiring routine use of original web UIs.
- The backend is inaccessible through the LAN address and rejects missing or invalid control tokens.
- Repeated mutations do not create duplicate requests, clients, indexers, or root folders.
- Destructive operations require two-step confirmation.
- Closing the app leaves the server running.

