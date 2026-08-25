# Changelog

All notable changes to Media Control are recorded here.

## [0.2.0] - 2026-08-25

- Split the Windows client into Content and System workspaces with responsive navigation, retained page state, prepared movie and series downloads, live download events with polling fallback, progressive Vietsub selection, and Jellyfin library links.
- Added stable gateway errors, abortable upstream requests, bounded caches and concurrency, shared download polling, source-aware partial release results, and legacy-compatible list routes.
- Reconciled qBittorrent, Radarr, Sonarr, Prowlarr, Jellyfin, and Bazarr configuration during first run, update, or manual repair without a permanent health poller.
- Simplified the Docker stack by retiring Autobrr and unused database services while preserving existing data during normal updates.
- Added an idempotent Windows installer flow, bilingual operator guides, release metadata, and the MIT license.
