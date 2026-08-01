# Isolated WSL Media Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision an isolated Ubuntu 24.04 WSL2 media server on `D:\WSL\MediaServer`, run the complete 13-service media stack on distro-local Docker Engine, and expose it only to the home LAN with Explorer-friendly media storage at `D:\Media`.

**Architecture:** A PowerShell installer owns Windows/WSL setup and invokes an idempotent Linux bootstrap. Reproducible Compose and post-start configuration scripts own the service layer. Application databases stay on ext4 under `/srv/media-stack`; the single NTFS data tree is mounted as `/data` everywhere.

**Tech Stack:** PowerShell 7/Windows PowerShell 5.1, WSL 2.7+, Ubuntu 24.04 LTS, Bash, Docker Engine/Compose v2, NVIDIA Container Toolkit, Compose YAML, REST APIs, Pester-free smoke checks.

## Global Constraints

- Preserve `Ubuntu`, `PCMClawUbuntu`, Docker Desktop, the default distro, and all existing data.
- Never call `wsl --unregister`; abort if `MediaServer` or `D:\WSL\MediaServer` already exists unexpectedly.
- Preserve `.wslconfig` values `processors=16` and `memory=8GB`; add only `networkingMode=mirrored` and `firewall=true` when absent.
- No Windows-login autostart, Internet-facing web UI, reverse proxy, TLS, VPN, router port-forwarding, or unattended image updates.
- Use `Asia/Ho_Chi_Minh`, UID/GID `1000:1000`, and one consistent `/data` mount.
- Treat Seerr v3 as the maintained successor to the requested Jellyseerr; do not deploy the retired Jellyseerr image.
- Never commit generated passwords, API keys, runtime `.env`, or application data.

---

### Task 1: Repository contracts and static validation

**Files:**
- Create: `.gitignore`
- Create: `infra/config/media-stack.json`
- Create: `infra/tests/Test-StaticConfig.ps1`

**Interfaces:**
- Produces one source of truth with distro name/path, media root, timezone, UID/GID, service ports, published LAN ports, and the 13 expected service names.
- The JSON keys are `distroName`, `distroPath`, `mediaRoot`, `timezone`, `puid`, `pgid`, `services`, and `ports`.

- [ ] **Step 1: Write the failing static contract test**

  The test loads `infra/config/media-stack.json`, asserts `MediaServer`, `D:\WSL\MediaServer`, `D:\Media`, exactly 13 unique services, qBittorrent host port `8081`, no published FlareSolverr port, and rejects any text matching `wsl\s+--unregister` in `infra/`.

- [ ] **Step 2: Run the test and confirm it fails because the manifest is absent**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -File infra/tests/Test-StaticConfig.ps1`

- [ ] **Step 3: Add the manifest and ignore rules**

  Use these service/port pairs: Jellyfin `8096`, Seerr `5055`, Radarr `7878`, Sonarr `8989`, Lidarr `8686`, Prowlarr `9696`, Bazarr `6767`, qBittorrent `8081`, SABnzbd `8085`, Autobrr `7474`, FlareSolverr `8191`, Cleanuparr `11011`, Wizarr `5690`. Ignore `.env`, `credentials*`, `deployment-report.json`, and runtime appdata.

- [ ] **Step 4: Run the static test and `git diff --check`**

  Expected: both pass.

- [ ] **Step 5: Commit**

  Run: `git add .gitignore infra/config infra/tests && git commit -m "test: define media server deployment contract"`

### Task 2: Safe WSL installation and global networking

**Files:**
- Create: `infra/windows/Install-MediaServer.ps1`
- Extend test: `infra/tests/Test-StaticConfig.ps1`

**Interfaces:**
- `Install-MediaServer.ps1 [-SkipDistroInstall] [-SkipFirewall]` returns nonzero on a failed preflight and is safe to rerun after successful installation.
- It invokes Linux scripts from the repository through `/mnt/c/Users/ASUS/Documents/WSL/infra/linux/...` and writes operator scripts to `D:\WSL` only after provisioning succeeds.

- [ ] **Step 1: Add failing source-level safety tests**

  Assert the installer checks free space (minimum 80 GB), checks `Ubuntu-24.04` is online, refuses an existing unregistered nonempty target, records the current default distro, and contains no delete/unregister operation.

- [ ] **Step 2: Implement preflight and distro creation**

  Create `D:\WSL` and `D:\Media` only when absent, then install with:

  ```powershell
  wsl.exe --install Ubuntu-24.04 --name MediaServer --location D:\WSL\MediaServer --no-launch
  ```

  Verify the registry `BasePath` resolves under `D:\WSL\MediaServer` and verify the previously recorded default distro did not change.

- [ ] **Step 3: Merge global WSL configuration without replacing unrelated settings**

  Update `%USERPROFILE%\.wslconfig` in place so `[wsl2]` retains `processors=16` and `memory=8GB`, and contains:

  ```ini
  networkingMode=mirrored
  firewall=true
  ```

  Save a timestamped backup beside the original before changing it. If any distro other than the new `MediaServer` is running, show the list and require an execution-time confirmation before the one necessary `wsl --shutdown`; record the prior state so the final report notes that Docker Desktop or another distro may need reopening.

- [ ] **Step 4: Create the Linux operator account**

  Launch as root, create user `media` with UID/GID 1000, add it to `sudo`, install `/etc/wsl.conf` with systemd enabled and DrvFS metadata options, then run `wsl --manage MediaServer --set-default-user media`.

- [ ] **Step 5: Validate idempotence**

  Run the installer with `-SkipDistroInstall`; expected: it recognizes the registered distro and makes no duplicate user/config entries.

- [ ] **Step 6: Commit**

  Run: `git add infra/windows infra/tests && git commit -m "feat: provision isolated Ubuntu WSL distro"`

### Task 3: Distro-local Docker Engine and NVIDIA runtime

**Files:**
- Create: `infra/linux/bootstrap-host.sh`
- Create: `infra/linux/verify-host.sh`

**Interfaces:**
- `bootstrap-host.sh` must be run as root inside `MediaServer`; it is idempotent and never installs Docker Desktop packages.
- `verify-host.sh` emits machine-readable `PASS|FAIL key detail` lines for OS, systemd, Docker, Compose, storage, and NVIDIA.

- [ ] **Step 1: Write host verification before bootstrap**

  Check Ubuntu `24.04`, systemd PID 1, `/mnt/d/Media` write access as UID 1000, `docker info`, `docker compose version`, `nvidia-smi`, and `docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi`.

- [ ] **Step 2: Confirm verification fails on the fresh distro**

  Run: `wsl -d MediaServer -u root -- bash /mnt/c/Users/ASUS/Documents/WSL/infra/linux/verify-host.sh`

- [ ] **Step 3: Install Docker from the official apt repository**

  Remove conflicting distro packages if present; add Docker's keyring and `download.docker.com/linux/ubuntu` Noble repository; install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin`. Add `media` to group `docker` and enable `docker.service` plus `containerd.service`.

- [ ] **Step 4: Install and configure NVIDIA Container Toolkit**

  Add NVIDIA's official `libnvidia-container` apt repository and keyring; install `nvidia-container-toolkit`; run `nvidia-ctk runtime configure --runtime=docker`; restart Docker. Do not install a Linux display driver inside WSL—the Windows NVIDIA driver supplies the WSL interface.

- [ ] **Step 5: Create host directories and verify permissions**

  Create `/srv/media-stack/{appdata,secrets,scripts}` owned by `media:media`; create the approved `D:\Media` tree through `/mnt/d/Media`; verify a Windows-created file is writable from the distro.

- [ ] **Step 6: Run host verification**

  Expected: all checks pass, including GPU visibility inside a throwaway container.

- [ ] **Step 7: Commit**

  Run: `git add infra/linux && git commit -m "feat: bootstrap Docker and NVIDIA in WSL"`

### Task 4: Compose the complete media stack

**Files:**
- Create: `infra/compose/compose.yaml`
- Create: `infra/compose/.env.example`
- Create: `infra/linux/generate-runtime-env.sh`
- Create: `infra/tests/verify-compose.sh`

**Interfaces:**
- `generate-runtime-env.sh /srv/media-stack/.env` writes unique random credentials with mode `0600` and never overwrites an existing nonempty secrets file.
- Compose project name is `media`; network name is `media_internal`; every relevant service receives `/mnt/d/Media:/data` with consistent paths.

- [ ] **Step 1: Write a failing Compose contract check**

  Assert exactly these services exist: `jellyfin`, `seerr`, `radarr`, `sonarr`, `lidarr`, `prowlarr`, `bazarr`, `qbittorrent`, `sabnzbd`, `autobrr`, `flaresolverr`, `cleanuparr`, `wizarr`. Assert restart policy, log rotation, expected ports, internal network, ext4 appdata mounts, and shared `/data` mappings.

- [ ] **Step 2: Define stable upstream images**

  Use official Jellyfin and Seerr images; LinuxServer stable images for Radarr/Sonarr/Lidarr/Prowlarr/Bazarr/qBittorrent/SABnzbd; upstream GHCR images for Autobrr/FlareSolverr/Cleanuparr/Wizarr. Use stable/major tags only, never nightly/develop. Record resolved image digests after the first successful pull in `/srv/media-stack/deployment-report.json` rather than committing them as credentials/config.

- [ ] **Step 3: Define mounts, ports, health, and resources**

  Give Jellyfin `/config`, `/cache`, read-only `/data/library`, and NVIDIA GPU reservation. Give the managers/downloaders the shared read-write `/data`. Map qBittorrent `8081:8080`, SABnzbd `8085:8080`, and the remaining approved UI ports. Do not publish FlareSolverr `8191` or a qBittorrent peer port; both remain internal/outbound-only. Add `json-file` logging with `max-size=10m,max-file=3`; use upstream health endpoints where valid; use conservative memory reservations without hard limits that could kill database writes.

- [ ] **Step 4: Generate runtime environment and validate Compose**

  Copy the Compose file to `/srv/media-stack/compose.yaml`, generate `/srv/media-stack/.env`, then run:

  ```bash
  cd /srv/media-stack
  docker compose config --quiet
  docker compose pull
  docker compose up -d
  ```

- [ ] **Step 5: Run the Compose contract and runtime checks**

  Expected: 13 containers exist; none are restarting; every published HTTP port answers or reports a documented initialization state.

- [ ] **Step 6: Commit**

  Run: `git add infra/compose infra/linux infra/tests && git commit -m "feat: define complete media compose stack"`

### Task 5: Idempotent service configuration and internal wiring

**Files:**
- Create: `infra/linux/configure-stack.sh`
- Create: `infra/linux/lib/servarr.sh`
- Create: `infra/linux/verify-integrations.sh`

**Interfaces:**
- `configure-stack.sh` reads `/srv/media-stack/.env`, waits with bounded retries, and may be rerun without duplicate root folders, clients, or applications.
- It writes `/srv/media-stack/deployment-report.json` with states `configured`, `awaiting_external_credentials`, or `failed`; secrets are redacted.

- [ ] **Step 1: Write integration checks before configuration**

  Verify Docker DNS names, fetch the Arr API keys from each ext4 `config.xml`, assert root folders, query download clients, query Prowlarr applications, check Jellyfin setup completion/GPU visibility, and check Seerr/Wizarr server connections. Mark Prowlarr indexers, SAB providers, and Autobrr trackers as `awaiting_external_credentials`, not failures.

- [ ] **Step 2: Configure qBittorrent and SABnzbd**

  Capture qBittorrent's one-time temporary password from its first-start log, authenticate through `/api/v2/auth/login`, set the generated admin password, categories `movies`, `tv`, and `music`, `/data/downloads/torrents` paths, and port `6881`. Configure SABnzbd with generated credentials, `/data/downloads/usenet/incomplete`, complete category folders, and its generated API key; do not invent a Usenet server.

- [ ] **Step 3: Configure Radarr, Sonarr, and Lidarr through their schemas**

  Add `/data/library/movies`, `/data/library/tv`, and `/data/library/music` respectively through `/api/v3/rootfolder`. Fetch `/api/v3/downloadclient/schema`, select the qBittorrent and SABnzbd implementations, populate fields by schema field name, then POST only when an equivalent client is absent. Enable authentication for remote/LAN requests with the generated per-service credentials.

- [ ] **Step 4: Configure Prowlarr and FlareSolverr**

  Read Arr API keys from their config files; fetch Prowlarr `/api/v1/applications/schema`; add Radarr/Sonarr/Lidarr by Docker DNS name and sync level `fullSync`. Add FlareSolverr as the available proxy at `http://flaresolverr:8191`, without attaching it to every future indexer automatically.

- [ ] **Step 5: Configure the user-facing services**

  Complete Jellyfin startup via `/Startup/Configuration`, `/Startup/User`, and `/Startup/Complete`; create Movies/TV/Music libraries at `/data/library/...`; enable NVIDIA NVENC/NVDEC and a cache/transcode directory under `/cache`. Use Seerr's installed OpenAPI v3 endpoints to authenticate to `http://jellyfin:8096`, select the three libraries, and add Radarr/Sonarr using Docker DNS names. Connect Wizarr to Jellyfin and Seerr using its installed API schema. Store only generated admin credentials in `/srv/media-stack/secrets/credentials.txt` mode `0600`.

- [ ] **Step 6: Configure Autobrr, Bazarr, and Cleanuparr conservatively**

  Connect Autobrr to qBittorrent and the Arr services but create no tracker filter without external credentials. Set Bazarr paths via its Sonarr/Radarr connections and leave subtitle-provider credentials awaiting input. Connect Cleanuparr to qBittorrent and all three Arr apps; enable queue cleanup only for failed/stalled downloads and explicitly disable deletion of imported library media.

- [ ] **Step 7: Run integration verification twice**

  Expected: the first run configures missing records; the second creates no duplicates. All internal links pass, and only external account items remain `awaiting_external_credentials`.

- [ ] **Step 8: Commit**

  Run: `git add infra/linux && git commit -m "feat: wire media services idempotently"`

### Task 6: Manual lifecycle, LAN firewall, and operator guide

**Files:**
- Create: `infra/windows/Start-MediaServer.ps1`
- Create: `infra/windows/Stop-MediaServer.ps1`
- Create: `infra/windows/Status-MediaServer.ps1`
- Create: `infra/windows/Update-MediaServer.ps1`
- Create: `infra/windows/Configure-MediaFirewall.ps1`
- Create: `README.md`

**Interfaces:**
- Installer copies the four lifecycle scripts to `D:\WSL`; each script has `-WhatIf` where it performs a mutation.
- Status output lists the Windows LAN URL for each UI and never prints secrets.

- [ ] **Step 1: Implement start/stop/status scripts**

  Start runs `wsl -d MediaServer -- systemctl is-active docker`, starts Docker if required, then `docker compose up -d`. Stop runs `docker compose stop --timeout 30` and `wsl --terminate MediaServer`. Status reports distro state, disk free space, `docker compose ps`, unhealthy/restarting containers, and URLs.

- [ ] **Step 2: Implement controlled update**

  Update records current image IDs, pulls stable tags, runs `docker compose config --quiet`, recreates services, waits for health, and prints rollback commands using the previous image IDs if any core service fails. It never runs on a schedule.

- [ ] **Step 3: Add least-scope LAN firewall rules**

  Require elevation; confirm the active Wi-Fi network is `Private`; add Windows and Hyper-V inbound TCP rules for the 12 published UI ports with `RemoteAddress LocalSubnet`. Do not open FlareSolverr or qBittorrent peer ports, change the router, or enable a Public-profile rule.

- [ ] **Step 4: Write the operator guide and Windows README**

  Document start/stop/status/update, URLs, credential-file location, how to add legal indexer/Usenet/subtitle credentials, and how to force a Jellyfin transcode. Have the installer generate `D:\Media\SERVER-README.txt` from the same port manifest without secrets.

- [ ] **Step 5: Run static and help-path checks**

  Invoke every PowerShell script with `-WhatIf` or its non-mutating status/help path; run `powershell -File infra/tests/Test-StaticConfig.ps1` and `git diff --check`.

- [ ] **Step 6: Commit**

  Run: `git add infra/windows README.md infra/tests && git commit -m "feat: add media server operations and LAN access"`

### Task 7: End-to-end deployment verification

**Files:**
- Create: `infra/tests/Verify-Deployment.ps1`
- Modify: `README.md`

**Interfaces:**
- `Verify-Deployment.ps1 [-LanClientAddress <IP>]` produces a redacted pass/fail summary and exits nonzero on any core failure.

- [ ] **Step 1: Verify isolation and persistence**

  Confirm `MediaServer` is WSL2, its registry base path is on D, default distro is unchanged, Docker root is inside `MediaServer`, and the two existing distros plus Docker Desktop registrations are unchanged.

- [ ] **Step 2: Verify storage semantics**

  Create a disposable file under `D:\Media\downloads\torrents\movies`, read/write it from qBittorrent and Radarr containers, attempt a hardlink into the Movies library, compare file IDs/inodes, then remove only the disposable probe. Record `hardlink` or `copy-fallback` in the report.

- [ ] **Step 3: Verify services and connections**

  Run `verify-host.sh`, `verify-compose.sh`, and `verify-integrations.sh`; require all 13 containers present and all core services healthy. Confirm the report contains no secrets.

- [ ] **Step 4: Verify LAN and restart behavior**

  Use the Windows LAN address to probe every UI locally, then ask the user to open Jellyfin and Seerr from a phone on home Wi-Fi. Stop and start through the copied scripts and require the stack to recover without starting or modifying the other distros.

- [ ] **Step 5: Verify NVIDIA transcoding with the user**

  Import a user-provided legal 4K sample, force a 1080p/low-bitrate client transcode, and verify Jellyfin's playback info reports NVENC while `docker exec jellyfin nvidia-smi` shows the process. Do not download copyrighted test media.

- [ ] **Step 6: Commit and push the completed infrastructure**

  Run all static tests and `git diff --check`, commit the verification additions, then push the current branch only after showing the user the final deployment summary.
