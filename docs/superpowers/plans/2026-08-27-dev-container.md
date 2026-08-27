# MediaDock Dev Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reproducible Docker-in-Docker Dev Container that runs MediaDock's Node, Python, Compose, and Flutter validation workflows without accessing the host media stack.

**Architecture:** Build on Ubuntu 24.04 and install the project-recorded Flutter 3.44.9 SDK from its checksum-verified official archive. Pinned official Dev Container features provide Node.js 22, PowerShell 7.5, and an isolated Docker 29 daemon; a development Compose override and generated ignored environment file keep all runtime state separate from `D:\Media` and host Docker.

**Tech Stack:** Dev Container Specification, Docker-in-Docker, Docker Compose v2, Ubuntu 24.04, Node.js 22, Python 3, PowerShell 7.5, Flutter 3.44.9/Dart 3.12.2, Node test runner

**Spec:** `docs/superpowers/specs/2026-08-27-dev-container-design.md`

## Global Constraints

- Opening the Dev Container must not start any MediaDock service.
- Never mount `/var/run/docker.sock` or otherwise expose the host Docker daemon.
- Never read, write, or reference production `.env`, `.env.compose`, or `D:\Media` from Dev Container setup.
- Use Flutter `3.44.9`, matching `flutter_app/.metadata` revision `6b182d2c7585eba26d4edce0f97630effd256c33`.
- Verify the official Linux Flutter archive with SHA-256 `a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb`.
- Windows Flutter and NSIS release builds remain host-only workflows.
- Before editing an existing function, class, or method, run GitNexus upstream impact analysis and report the risk; this plan is designed to avoid existing symbol edits.
- Before every commit, run GitNexus `detect_changes({scope: "compare", base_ref: "main"})`. If GitNexus remains unavailable, leave the verified changes uncommitted rather than bypassing the repository rule.
- Preserve all pre-existing staged, unstaged, and untracked user changes.
- Execute from an isolated `codex/dev-container` worktree based on
  `mediadock/main`; the current `codex/windows-installer` checkout is dirty and
  must not be normalized, reset, or reused for implementation.

---

## File Structure

- `.devcontainer/devcontainer.json` — editor-facing container definition, pinned features, ports, lifecycle command, and resource guidance.
- `.devcontainer/Dockerfile` — Ubuntu 24.04 base, Linux test dependencies, and checksum-verified Flutter SDK.
- `.devcontainer/compose.devcontainer.yaml` — isolated Compose project/network overlay.
- `.devcontainer/post-create.sh` — idempotent tool checks, private development environment generation, Flutter dependency restore, and Compose validation.
- `host-controller/test/devcontainer.test.mjs` — static safety and lifecycle contract for every Dev Container file.
- `.gitignore` — excludes generated Dev Container credentials and data.
- `README.md` — fixes the existing heading regression and documents container and host workflows.

### Task 1: Restore the Green Documentation Baseline

**Files:**
- Modify: `README.md:1-3`
- Test: `host-controller/test/installer.test.mjs:243`

**Interfaces:**
- Consumes: the existing README heading contract in `installer.test.mjs`.
- Produces: the unchanged five-heading public README structure required by later documentation edits.

- [ ] **Step 1: Run the existing regression test and confirm the expected failure**

Run from `host-controller`:

```bash
node --test --test-name-pattern="README has the requested English-only structure"
```

Expected: FAIL because the student-project warning is currently parsed as a sixth `##` heading.

- [ ] **Step 2: Make the warning prose instead of document structure**

Replace:

```markdown
## This project is a student-built prototype and may contain bugs or incomplete features. Contributions are welcome—feel free to fork the repository, submit pull requests, and help improve the project.
```

with:

```markdown
> This project is a student-built prototype and may contain bugs or incomplete features. Contributions are welcome—feel free to fork the repository, submit pull requests, and help improve the project.
```

- [ ] **Step 3: Verify the focused test is green**

Run the command from Step 1.

Expected: PASS with no change to the documented warning text.

- [ ] **Step 4: Check affected scope and commit only the README correction**

Run GitNexus `detect_changes({scope: "compare", base_ref: "main"})` and confirm no execution flow changes. If it succeeds:

```bash
git add README.md
git commit -m "docs: fix README heading structure"
```

Expected: the commit contains only `README.md`. If GitNexus is unavailable, do not commit.

### Task 2: Add the Pinned Isolated Toolchain

**Files:**
- Create: `host-controller/test/devcontainer.test.mjs`
- Create: `.devcontainer/devcontainer.json`
- Create: `.devcontainer/Dockerfile`

**Interfaces:**
- Consumes: Flutter version and revision from `flutter_app/.metadata`; official Dev Container feature contracts.
- Produces: `devcontainer.json` as the editor entry point and `/opt/flutter/bin/flutter` on `PATH` for later setup.

- [ ] **Step 1: Write the failing toolchain contract**

Create `host-controller/test/devcontainer.test.mjs`:

```js
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');

test('dev container pins the isolated cross-platform toolchain', () => {
  const config = JSON.parse(read('.devcontainer/devcontainer.json'));
  const dockerfile = read('.devcontainer/Dockerfile');

  assert.equal(config.remoteUser, 'vscode');
  assert.equal(config.build.dockerfile, 'Dockerfile');
  assert.deepEqual(config.features['ghcr.io/devcontainers/features/node:2.1.0'], {
    version: '22',
    pnpmVersion: 'none',
  });
  assert.deepEqual(config.features['ghcr.io/devcontainers/features/powershell:2.0.2'], {
    version: '7.5',
  });
  assert.deepEqual(config.features['ghcr.io/devcontainers/features/docker-in-docker:3.0.1'], {
    version: '29',
    moby: true,
    dockerDashComposeVersion: 'v2',
  });
  assert.match(dockerfile, /FROM mcr\.microsoft\.com\/devcontainers\/base:ubuntu-24\.04/);
  assert.match(dockerfile, /FLUTTER_VERSION=3\.44\.9/);
  assert.match(dockerfile, /a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb/);
  assert.doesNotMatch(JSON.stringify(config), /docker-outside-of-docker|\/var\/run\/docker\.sock/);
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run from `host-controller`:

```bash
node --test test/devcontainer.test.mjs
```

Expected: FAIL with `ENOENT` for `.devcontainer/devcontainer.json`.

- [ ] **Step 3: Add the minimal checksum-verified Flutter image**

Create `.devcontainer/Dockerfile`:

```dockerfile
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG FLUTTER_VERSION=3.44.9
ARG FLUTTER_SHA256=a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libglu1-mesa \
        openssl \
        python3 \
        python3-pip \
        python3-venv \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
        -o /tmp/flutter.tar.xz \
    && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/flutter.tar.xz -C /opt \
    && chown -R vscode:vscode /opt/flutter \
    && git config --system --add safe.directory /opt/flutter \
    && rm /tmp/flutter.tar.xz

ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"
```

- [ ] **Step 4: Add the editor and feature configuration**

Create `.devcontainer/devcontainer.json`:

```json
{
  "name": "MediaDock",
  "build": {
    "dockerfile": "Dockerfile",
    "context": ".."
  },
  "remoteUser": "vscode",
  "features": {
    "ghcr.io/devcontainers/features/node:2.1.0": {
      "version": "22",
      "pnpmVersion": "none"
    },
    "ghcr.io/devcontainers/features/powershell:2.0.2": {
      "version": "7.5"
    },
    "ghcr.io/devcontainers/features/docker-in-docker:3.0.1": {
      "version": "29",
      "moby": true,
      "dockerDashComposeVersion": "v2"
    }
  },
  "forwardPorts": [3000, 5055, 6767, 7878, 8080, 8096, 8989, 9696],
  "portsAttributes": {
    "3000": { "label": "MediaDock API" },
    "8096": { "label": "Jellyfin" },
    "5055": { "label": "Seerr" }
  },
  "hostRequirements": {
    "cpus": 4,
    "memory": "8gb",
    "storage": "32gb"
  },
  "customizations": {
    "vscode": {
      "extensions": [
        "Dart-Code.flutter",
        "ms-azuretools.vscode-docker",
        "ms-python.python",
        "ms-vscode.powershell"
      ]
    }
  }
}
```

- [ ] **Step 5: Verify GREEN and validate JSON**

Run:

```bash
node --test host-controller/test/devcontainer.test.mjs
node -e "JSON.parse(require('node:fs').readFileSync('.devcontainer/devcontainer.json', 'utf8'))"
```

Expected: PASS and exit code 0.

- [ ] **Step 6: Check affected scope and commit the toolchain unit**

Run GitNexus `detect_changes({scope: "compare", base_ref: "main"})`. If it succeeds:

```bash
git add .devcontainer/Dockerfile .devcontainer/devcontainer.json host-controller/test/devcontainer.test.mjs
git commit -m "build: add isolated development toolchain"
```

Expected: only the three listed files are committed. If GitNexus is unavailable, do not commit.

### Task 3: Add Idempotent Development State and Compose Isolation

**Files:**
- Modify: `.devcontainer/devcontainer.json`
- Modify: `host-controller/test/devcontainer.test.mjs`
- Create: `.devcontainer/compose.devcontainer.yaml`
- Create: `.devcontainer/post-create.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `docker`, `docker compose`, `flutter`, `node`, `python3`, and `pwsh` installed by Task 2.
- Produces: ignored `.devcontainer/.env.devcontainer`, ignored `.devcontainer/data/`, and the explicit isolated Compose command used by documentation and developers.

- [ ] **Step 1: Add failing lifecycle and data-isolation contracts**

Append to `host-controller/test/devcontainer.test.mjs`:

```js
test('dev setup is opt-in, idempotent, and isolated from production data', () => {
  const config = JSON.parse(read('.devcontainer/devcontainer.json'));
  const compose = read('.devcontainer/compose.devcontainer.yaml');
  const setup = read('.devcontainer/post-create.sh');
  const ignore = read('.gitignore');
  const combined = `${JSON.stringify(config)}\n${compose}\n${setup}`;

  assert.equal(config.postCreateCommand, 'bash .devcontainer/post-create.sh');
  assert.match(compose, /^name: mediadock-dev$/m);
  assert.match(compose, /name: mediadock-dev-media/);
  assert.match(setup, /\.env\.devcontainer/);
  assert.match(setup, /openssl rand -hex 32/);
  assert.match(setup, /flutter pub get/);
  assert.match(setup, /docker compose[\s\S]*config -q/);
  assert.doesNotMatch(setup, /docker compose[\s\S]*\bup\b/);
  assert.doesNotMatch(combined, /D:\\Media|\.env\.compose|\/var\/run\/docker\.sock/);
  assert.match(ignore, /^\.devcontainer\/\.env\.devcontainer$/m);
  assert.match(ignore, /^\.devcontainer\/data\/$/m);
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
node --test host-controller/test/devcontainer.test.mjs
```

Expected: the toolchain test passes and the new lifecycle test fails with `ENOENT` for `compose.devcontainer.yaml`.

- [ ] **Step 3: Add the isolated Compose identity**

Create `.devcontainer/compose.devcontainer.yaml`:

```yaml
name: mediadock-dev

networks:
  media:
    name: mediadock-dev-media
```

- [ ] **Step 4: Add the idempotent post-create setup**

Create `.devcontainer/post-create.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
env_file="${repo_root}/.devcontainer/.env.devcontainer"
data_root="${repo_root}/.devcontainer/data"

for required in docker flutter node openssl python3 pwsh; do
  if ! command -v "${required}" >/dev/null 2>&1; then
    echo "Missing required development tool: ${required}" >&2
    exit 1
  fi
done

mkdir -p \
  "${data_root}/backups" \
  "${data_root}/cache" \
  "${data_root}/config" \
  "${data_root}/library/movies" \
  "${data_root}/library/tv" \
  "${data_root}/torrents"

if [[ ! -f "${env_file}" ]]; then
  umask 077
  subtitle_secret="$(openssl rand -hex 32)"
  tv_secret="$(openssl rand -hex 32)"
  printf '%s\n' \
    "MEDIA_ROOT=${data_root}" \
    "MEDIA_ROOT_DOCKER=${data_root}" \
    'PUID=1000' \
    'PGID=1000' \
    'TZ=Asia/Ho_Chi_Minh' \
    'LOCAL_ADMIN_USER=admin' \
    'LOCAL_ADMIN_PASSWORD=media1234' \
    "SUBTITLE_TOKEN_SECRET=${subtitle_secret}" \
    "TV_DOWNLOAD_TOKEN_SECRET=${tv_secret}" \
    'YIFY_DIRECT_ENABLED=false' \
    > "${env_file}"
fi

flutter config --no-analytics
(cd "${repo_root}/flutter_app" && flutter pub get)
docker compose \
  --env-file "${env_file}" \
  -f "${repo_root}/docker-compose.yml" \
  -f "${repo_root}/.devcontainer/compose.devcontainer.yaml" \
  config -q
```

- [ ] **Step 5: Attach the idempotent setup lifecycle**

Add this top-level property to `.devcontainer/devcontainer.json`:

```json
"postCreateCommand": "bash .devcontainer/post-create.sh"
```

- [ ] **Step 6: Ignore generated credentials and state**

Append to `.gitignore`:

```gitignore

# Dev Container private state
.devcontainer/.env.devcontainer
.devcontainer/data/
```

- [ ] **Step 7: Verify the focused contracts and Compose model**

Run:

```bash
node --test host-controller/test/devcontainer.test.mjs
bash -n .devcontainer/post-create.sh
```

Inside the built Dev Container, run:

```bash
bash .devcontainer/post-create.sh
bash .devcontainer/post-create.sh
docker compose --env-file .devcontainer/.env.devcontainer -f docker-compose.yml -f .devcontainer/compose.devcontainer.yaml config -q
```

Expected: both setup runs pass, the second preserves the two generated secrets, and Compose validation exits 0 without starting services.

- [ ] **Step 8: Check affected scope and commit the isolated lifecycle unit**

Run GitNexus `detect_changes({scope: "compare", base_ref: "main"})`. If it succeeds:

```bash
git add .devcontainer/devcontainer.json .devcontainer/compose.devcontainer.yaml .devcontainer/post-create.sh .gitignore host-controller/test/devcontainer.test.mjs
git commit -m "build: isolate MediaDock development state"
```

Expected: only the four listed files are committed. If GitNexus is unavailable, do not commit.

### Task 4: Document Workflows and Verify the Complete Environment

**Files:**
- Modify: `README.md` under `## Installation Instructions`
- Test: `host-controller/test/devcontainer.test.mjs`
- Test: `host-controller/test/installer.test.mjs`

**Interfaces:**
- Consumes: the exact setup and Compose commands produced by Tasks 2 and 3.
- Produces: contributor-facing instructions that distinguish container validation from Windows release building.

- [ ] **Step 1: Add a failing documentation contract**

Append to `host-controller/test/devcontainer.test.mjs`:

```js
test('README documents isolated development and host-only Windows releases', () => {
  const readme = read('README.md');

  assert.match(readme, /### Dev Container/);
  assert.match(readme, /Reopen in Container/);
  assert.match(readme, /compose\.devcontainer\.yaml/);
  assert.match(readme, /flutter analyze/);
  assert.match(readme, /flutter test/);
  assert.match(readme, /Windows host.*NSIS/is);
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
node --test host-controller/test/devcontainer.test.mjs
```

Expected: FAIL because `README.md` has no `### Dev Container` section.

- [ ] **Step 3: Add the contributor workflow below the source-build instructions**

Add this subsection under `## Installation Instructions` without adding another level-one or level-two heading:

````markdown
### Dev Container

For an isolated Linux development environment, install a Dev Container-compatible editor and choose **Reopen in Container**. The container provides Node.js, Python, PowerShell, Flutter, and a private Docker-in-Docker daemon. Opening it does not start the media stack and does not access the host Docker daemon or `D:\Media`.

Run the repository checks inside the container:

```bash
(cd backend && node --test)
(cd host-controller && node --test)
python3 -m unittest scripts/test_bazarr_profile.py
(cd flutter_app && flutter analyze && flutter test)
```

Start the isolated media stack only when integration testing requires it:

```bash
docker compose --env-file .devcontainer/.env.devcontainer -f docker-compose.yml -f .devcontainer/compose.devcontainer.yaml up -d
```

Stop it without deleting development data:

```bash
docker compose --env-file .devcontainer/.env.devcontainer -f docker-compose.yml -f .devcontainer/compose.devcontainer.yaml stop
```

Flutter Windows executables and the NSIS installer must still be built on the Windows host with the release command below.
````

- [ ] **Step 4: Run all repository tests available inside the container**

Run:

```bash
(cd backend && node --test)
(cd host-controller && node --test)
python3 -m unittest scripts/test_bazarr_profile.py
(cd flutter_app && flutter analyze && flutter test)
```

Expected: all Node and Python tests pass; Flutter analysis and tests pass under Flutter 3.44.9.

- [ ] **Step 5: Build and smoke-test the Dev Container**

From a host with the Dev Container CLI:

```bash
devcontainer build --workspace-folder .
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash .devcontainer/post-create.sh
devcontainer exec --workspace-folder . docker info
```

Expected: build and setup succeed, `docker info` reports the nested daemon, and `docker ps` contains no MediaDock services until the explicit Compose `up` command is run.

- [ ] **Step 6: Validate opt-in Compose startup and cleanup**

Inside the Dev Container:

```bash
docker compose --env-file .devcontainer/.env.devcontainer -f docker-compose.yml -f .devcontainer/compose.devcontainer.yaml up -d api
curl --fail --retry 20 --retry-delay 2 http://127.0.0.1:3000/health
docker compose --env-file .devcontainer/.env.devcontainer -f docker-compose.yml -f .devcontainer/compose.devcontainer.yaml down
```

Expected: the API health endpoint returns `{"status":"ready"}` and only development project resources are removed. Do not add `--volumes`, so development state is preserved.

- [ ] **Step 7: Run final GitNexus scope validation and commit documentation**

Run GitNexus `detect_changes({scope: "compare", base_ref: "main"})` and verify that only the new Dev Container contract and documentation are affected. If it succeeds:

```bash
git add README.md host-controller/test/devcontainer.test.mjs
git commit -m "docs: document isolated development workflow"
```

Expected: only the two listed files are committed. If GitNexus is unavailable, do not commit.

## Plan Self-Review

- Spec coverage: toolchain pinning, Docker isolation, private state, opt-in startup, error handling, documentation, and full validation each map to a task.
- Placeholder scan: no deferred implementation steps or unspecified error handling remain.
- Interface consistency: every command uses `.devcontainer/.env.devcontainer` and `.devcontainer/compose.devcontainer.yaml`; Docker-in-Docker is consistently provided by `ghcr.io/devcontainers/features/docker-in-docker:3.0.1`.
- Scope: the plan adds one development environment and its contracts; Windows release production behavior remains unchanged.
