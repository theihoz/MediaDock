# MediaDock Dev Container Design

## Purpose

Provide a reproducible, isolated development environment for MediaDock that
supports the repository's Node.js, Python, PowerShell, Docker Compose, and
Flutter validation workflows without touching the operator's production media
stack or `D:\Media` data.

The Linux Dev Container will support Flutter analysis and tests. Building the
Flutter Windows executable and NSIS installer remains a Windows-host workflow
because a Linux container cannot produce or validate the Windows desktop
runner reliably.

## Current Architecture

MediaDock has four runtime layers:

1. The Flutter Windows client presents discovery, downloads, subtitles,
   library, and system controls.
2. The loopback-only Node.js host controller starts and stops Docker Compose
   services and performs host maintenance.
3. The Node.js API gateway normalizes provider APIs and protects credentials,
   file paths, release tokens, and destructive operations from the client.
4. Docker Compose runs qBittorrent, Prowlarr, Radarr, Sonarr, Bazarr, Jellyfin,
   Seerr, FlareSolverr, and the API gateway.

Development tooling also includes Python tests and configuration helpers,
PowerShell installer and provider scripts, and Flutter widget and contract
tests.

## Chosen Approach

Use one Linux Dev Container with Docker-in-Docker. The nested Docker daemon is
isolated from Docker Desktop's host daemon, so development commands cannot
stop, recreate, or delete the user's real MediaDock containers and volumes.

This approach is preferred over mounting the host Docker socket. A host socket
would be lighter but would expose the production Docker daemon and introduce
ambiguous Windows/Linux bind paths. A toolchain-only container was rejected
because it could not validate Compose or API-to-provider integration.

## Components

### `.devcontainer/devcontainer.json`

- Defines the development image build and workspace settings.
- Enables Docker-in-Docker rather than Docker-outside-of-Docker.
- Forwards the API, Jellyfin, Seerr, and Arr development ports without opening
  them publicly by default.
- Runs the idempotent post-create setup script.
- Does not start the media stack automatically.

### `.devcontainer/Dockerfile`

- Uses a maintained Ubuntu-based Dev Container base image.
- Installs Python 3 and the Flutter 3.44.9 SDK recorded by the project's
  `.metadata`, with the official archive checksum verified during the build.
- Works with pinned official Dev Container features that install Node.js 22,
  PowerShell 7.5, and Docker-in-Docker.
- Includes only development tools; it does not copy secrets or production
  configuration into the image.
- Supports both `amd64` and `arm64` where the selected upstream tools provide
  binaries.

### `.devcontainer/compose.devcontainer.yaml`

- Extends the repository Compose model for development.
- Uses a distinct Compose project name and isolated network.
- Replaces production media bind mounts with development-only storage visible
  to the nested Docker daemon.
- Keeps the repository source mount read-only where a service only needs to
  consume scripts.
- Preserves the production rule that the media stack does not start merely
  because the development container opens.

### `.devcontainer/post-create.sh`

- Verifies the installed toolchain and fails with a specific diagnostic when a
  required command is unavailable.
- Runs `flutter pub get` in `flutter_app`.
- Creates an ignored, development-only Compose environment file when missing.
- Generates local development token secrets without reading or overwriting the
  production `.env` or `.env.compose` files.
- Is safe to run repeatedly.

### `host-controller/test/devcontainer.test.mjs`

The repository already uses Node tests to verify installer, README, and
Compose contracts. A new contract test will verify that the Dev Container:

- selects Docker-in-Docker and does not mount the host Docker socket;
- never references `D:\Media` or production environment files;
- does not run `docker compose up` during creation;
- pins the required major toolchain versions;
- declares the intended development environment and commands; and
- keeps generated credentials and development state ignored by Git.

### Documentation

The README will document how to reopen the repository in the Dev Container,
run each test suite, start the isolated Compose stack explicitly, and build the
Windows release on the host. The existing student-project warning will be
rendered as prose instead of a level-two heading so the documented README
structure and its existing contract test agree.

## Lifecycle and Data Flow

1. The editor builds and opens the development container.
2. Docker-in-Docker starts a private daemon inside the development container.
3. The post-create script installs project-level dependencies and creates the
   ignored development environment file.
4. No MediaDock runtime service starts until the developer runs the documented
   Compose command.
5. When started, provider containers and the API use the nested daemon's
   development-only storage and network.
6. Forwarded loopback ports let the developer inspect services from the host.
7. Removing the Dev Container removes or leaves only explicitly named
   development volumes; it never changes `D:\Media` or host Docker resources.

## Secrets and Safety

- No production credentials are copied into the image or generated files.
- Development secrets are random local values and are excluded from Git.
- The host Docker socket is not mounted.
- Production bootstrap, firewall, WSL installation, installer, and uninstaller
  workflows are not run inside the container.
- The full media stack is opt-in after the container opens.
- Destructive tests continue to use temporary directories and test-owned
  markers.

## Error Handling

The post-create script uses strict shell behavior and reports which required
tool or setup step failed. It can be rerun without rotating existing local
development secrets or deleting development data.

Compose validation happens before a documented start command. A malformed
override or missing variable therefore fails before provider containers are
created. Flutter dependency failures do not trigger Compose startup.

## Verification Strategy

Implementation follows red-green-refactor:

1. Add the Dev Container contract test and confirm it fails because the
   configuration does not exist.
2. Add the smallest configuration needed to satisfy each safety and lifecycle
   contract.
3. Validate `devcontainer.json` as JSON and render the combined Compose model
   with `docker compose config`.
4. Run all backend Node tests.
5. Run all host-controller Node tests, including the Dev Container contract.
6. Run the Python tests.
7. Run `flutter analyze` and `flutter test` inside an environment with Flutter
   available.
8. Smoke-test the nested Docker daemon and the explicit Compose start path when
   the host permits privileged containers.

The current `mediadock/main` baseline has 142 passing backend tests, 5 passing
Python tests, and 55 of 56 passing host-controller tests. The one existing
failure is the README heading regression described above; correcting its
markup is included so the final baseline can be green.

## Non-Goals

- Building or signing the Flutter Windows executable in Linux.
- Building the NSIS installer in Linux.
- Automatically starting every media provider on container creation.
- Replacing the production installer, bootstrap, or Compose deployment model.
- Making development services accessible beyond the local workstation.
- Installing or configuring WSL, Docker Desktop, or Windows firewall rules.

## Success Criteria

- A contributor can reopen the repository in the Dev Container and obtain the
  required cross-platform development toolchain without manual installation.
- Opening the container does not start MediaDock services or access production
  Docker resources and media data.
- The repository's Node, Python, Compose, and Flutter validation commands are
  documented and runnable in the appropriate environment.
- Dev Container safety constraints are covered by automated contract tests.
- Windows release limitations and host build commands are explicit.
