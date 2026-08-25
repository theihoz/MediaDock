# Media Control
## This project is a student-built prototype and may contain bugs or incomplete features. Contributions are welcome—feel free to fork the repository, submit pull requests, and help improve the project.
Media Control is a Windows desktop dashboard for a self-hosted movie and TV stack. A Flutter client controls one local Node gateway and the existing Docker providers while keeping service credentials outside the app. It offers discovery, prepared downloads, live download status, Vietnamese subtitle workflows, a Jellyfin library, and local service controls.

The detailed guides are available in [English](docs/guide.en.md) and [Vietnamese](docs/guide.vi.md). Release history is recorded in the [changelog](CHANGELOG.md).

## Installation Instructions

Media Control requires 64-bit Windows 10 or newer, WSL2 with Ubuntu, Docker Desktop, the Microsoft Visual C++ 2015–2022 x64 runtime, and at least 10 GB free on the media drive. The default media root is `D:\Media`.

To build the unsigned installer from source, install Flutter with Windows desktop support and NSIS 3.x, then run PowerShell as Administrator:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-installer.ps1
```

Run `dist\install.exe` as Administrator. The installer places the app in `C:\Program Files\Media Control` and the private stack in `C:\ProgramData\MediaControl\stack`. It prepares local configuration without starting the media containers.

For a source-only setup from Ubuntu WSL:

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh --keep-running
```

Keep `.env` and `.env.compose` private. They contain local credentials and generated secrets.

## Usage

Open Media Control and start the server from the System workspace. The Content workspace contains Discovery, Downloads, Vietsub, and Library. The System workspace contains Overview, Services, and Settings. Pages are loaded on first use and retain their state when switching workspaces.

The first server start configures the providers. Later updates reconcile provider configuration automatically; an operator can run the repair command shown below at any time. Downloads prefer the live event stream and fall back to adaptive polling when the stream is unavailable.

Stop the stack without deleting data:

```bash
docker compose --env-file .env.compose stop
```

## Examples / Demos

Check the local gateway and inspect live download snapshots:

```bash
curl http://localhost:3000/health
curl -N http://localhost:3000/v1/downloads/events
```

Reconcile provider settings without repeating first-run jobs:

```bash
./scripts/bootstrap.sh --repair
```

See the [English guide](docs/guide.en.md) or [Vietnamese guide](docs/guide.vi.md) for custom media roots, provider options, Docker commands, troubleshooting, and safe removal.

## License

Media Control is released under the [MIT License](LICENSE). Copyright © 2026 theihoz.
