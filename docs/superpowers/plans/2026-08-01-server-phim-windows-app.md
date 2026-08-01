# Server Phim Windows App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a local-only Flutter Windows control application and loopback FastAPI backend for the existing WSL media server.

**Architecture:** Complete and verify the current media stack first. Add a loopback-only `media-control` service that normalizes upstream APIs, then build a Flutter Windows client against its versioned contract while retaining PowerShell ownership of WSL lifecycle.

**Tech Stack:** Flutter 3.44/Dart 3.12, Material 3, Riverpod, go_router, FastAPI/Pydantic, pytest, Docker Compose, PowerShell, Windows Credential Manager.

## Global Constraints

- Administrative access remains local to this Windows PC; `media-control` binds only `127.0.0.1:11444`.
- Do not alter or remove the existing `Ubuntu`, `PCMClawUbuntu`, or Docker Desktop distributions.
- Do not commit generated passwords, API keys, control tokens, runtime `.env`, appdata, or provider credentials.
- Server startup stays manual and closing the app must not stop WSL or Docker.
- Default request quality is 1080p with an explicit per-item 4K choice.
- Subtitle policy is Vietnamese preferred with English fallback.
- Use test-first development for backend and Flutter behavior.

---

### Task 1: Finish and verify the existing stack

- [ ] Extend static/integration tests for lifecycle, firewall, download clients, Arr/Prowlarr/Bazarr wiring, and secret redaction; observe the required failures.
- [ ] Complete idempotent qBittorrent, SABnzbd, Servarr, Prowlarr, Bazarr, Autobrr, Cleanuparr, and Wizarr configuration without inventing external credentials.
- [ ] Complete Start/Stop/Status/Update scripts, operator documentation, storage/hardlink checks, GPU checks, and LAN verification.
- [ ] Run configuration twice to prove no duplicates; commit and push the completed infrastructure checkpoint.

### Task 2: Define the media-control contract

- [ ] Write failing contract tests for authentication, common models, health aggregation, idempotency, redaction, confirmation tokens, and loopback binding.
- [ ] Implement the minimal FastAPI project, token bootstrap, settings, error envelope, and SSE heartbeat to pass the contract.
- [ ] Add the container to Compose with internal service DNS and `127.0.0.1:11444:11444`; verify it is unreachable through the LAN address.
- [ ] Commit the backend contract checkpoint.

### Task 3: Implement read adapters and aggregation

- [ ] Write failing adapter tests from redacted fixtures for Jellyfin/Seerr, Servarr/Prowlarr, Bazarr, downloaders, and auxiliary services.
- [ ] Implement focused adapters and normalized status, discover, library, download, subtitle, storage, profile, client, provider, and indexer reads.
- [ ] Add bounded timeouts and per-service degraded results so optional failures do not hide healthy modules.
- [ ] Run unit, contract, and live integration tests; commit the read-only backend checkpoint.

### Task 4: Implement guarded mutations

- [ ] Write failing tests for request idempotency, 1080p/4K profile mapping, queue controls, subtitle search, administration CRUD, and two-step deletion.
- [ ] Implement mutations using upstream schemas rather than fixed field positions; preserve existing configuration and reject ambiguous destructive targets.
- [ ] Add short-lived, single-use confirmation tokens and redact all mutation errors.
- [ ] Run mutation tests twice against the live stack to prove idempotence; commit the backend feature checkpoint.

### Task 5: Build the Flutter application shell

- [ ] Create the Flutter Windows project and failing tests for routing, server-off state, token storage boundary, and the six destinations.
- [ ] Implement the Material 3 design system, navigation shell, API/SSE clients, Riverpod state, WSL lifecycle gateway, secure token bootstrap, and degraded-state components.
- [ ] Verify keyboard focus, Vietnamese copy, empty/error states, and window resizing; commit the application shell checkpoint.

### Task 6: Implement feature screens

- [ ] Add failing widget/controller tests for Overview, Discover, Library, Downloads, Subtitles, and Administration.
- [ ] Implement one-click 1080p requests with a 4K toggle, unified queues, subtitle policy/status, deep configuration forms, and diagnostic original-UI links.
- [ ] Add two-step confirmation UI for destructive actions and keep server state independent of app window lifetime.
- [ ] Run Flutter unit/widget tests and live desktop smoke tests; commit the feature checkpoint.

### Task 7: Package, document, and verify

- [ ] Add failing packaging/static checks for release location, shortcuts, no autostart, token exclusion, and rollback metadata.
- [ ] Build the Windows release, install to `D:\WSL\ServerPhimApp`, create Desktop/Start Menu shortcuts, and add explicit app/backend update scripts.
- [ ] Run backend tests, Flutter analyze/tests, Compose checks, security probes, restart recovery, and end-to-end acceptance scenarios.
- [ ] Document external credential setup and known credential-dependent states; commit and push the finished branch.

