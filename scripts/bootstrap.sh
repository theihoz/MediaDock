#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
MEDIA_ROOT_DEFAULT=/mnt/d/Media
KEEP_RUNNING=false
if [[ "${1:-}" == "--keep-running" ]]; then KEEP_RUNNING=true; shift; fi
[[ $# == 0 ]] || { echo "Unknown bootstrap argument: $1" >&2; exit 2; }

require() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
secret() { openssl rand -hex 24; }

DOCKER=(docker)
if ! docker compose version >/dev/null 2>&1; then
  DOCKER_EXE="/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"
  if [[ ! -x "$DOCKER_EXE" ]]; then
    DOCKER_EXE="/mnt/c/Users/${SUDO_USER:-${USER:-}}/AppData/Local/Programs/DockerDesktop/resources/bin/docker.exe"
  fi
  if [[ ! -x "$DOCKER_EXE" && "$(id -u)" == 0 && -d /mnt/c/Users ]]; then
    WINDOWS_USER="$(basename "$(find /mnt/c/Users -mindepth 1 -maxdepth 1 -type d ! -name Public ! -name Default -print -quit)")"
    DOCKER_EXE="/mnt/c/Users/$WINDOWS_USER/AppData/Local/Programs/DockerDesktop/resources/bin/docker.exe"
  fi
  [[ -x "$DOCKER_EXE" ]] || { echo "Docker Desktop WSL integration is disabled and docker.exe was not found." >&2; exit 1; }
  DOCKER=("$DOCKER_EXE")
fi
"${DOCKER[@]}" compose version >/dev/null

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT_DIR/.env.example" "$ENV_FILE"
  sed -i "s/replace-with-a-long-random-password/$(secret)/" "$ENV_FILE"
  sed -i "s/replace-with-a-long-random-password/$(secret)/" "$ENV_FILE"
fi

sed -i 's/\r$//' "$ENV_FILE"

grep -q '^LOCAL_ADMIN_USER=' "$ENV_FILE" || printf '\nLOCAL_ADMIN_USER=admin\n' >> "$ENV_FILE"
grep -q '^LOCAL_ADMIN_PASSWORD=' "$ENV_FILE" || printf 'LOCAL_ADMIN_PASSWORD=media1234\n' >> "$ENV_FILE"
if ! grep -q '^HOST_CONTROLLER_TOKEN=' "$ENV_FILE"; then printf 'HOST_CONTROLLER_TOKEN=%s\n' "$(secret)" >> "$ENV_FILE"; fi
if grep -q '^HOST_CONTROLLER_TOKEN=replace-with-a-long-random-token$' "$ENV_FILE"; then sed -i "s/^HOST_CONTROLLER_TOKEN=.*/HOST_CONTROLLER_TOKEN=$(secret)/" "$ENV_FILE"; fi
grep -q '^JELLYFIN_API_KEY=' "$ENV_FILE" || printf 'JELLYFIN_API_KEY=\n' >> "$ENV_FILE"
grep -q '^YIFY_DIRECT_ENABLED=' "$ENV_FILE" || printf 'YIFY_DIRECT_ENABLED=false\n' >> "$ENV_FILE"
grep -q '^YIFY_DIRECT_BASE_URL=' "$ENV_FILE" || printf 'YIFY_DIRECT_BASE_URL=\n' >> "$ENV_FILE"
if ! grep -q '^SUBTITLE_TOKEN_SECRET=' "$ENV_FILE"; then printf 'SUBTITLE_TOKEN_SECRET=%s\n' "$(secret)" >> "$ENV_FILE"; fi
if grep -q '^SUBTITLE_TOKEN_SECRET=replace-with-a-long-random-token$' "$ENV_FILE"; then sed -i "s/^SUBTITLE_TOKEN_SECRET=.*/SUBTITLE_TOKEN_SECRET=$(secret)/" "$ENV_FILE"; fi
if ! grep -q '^TV_DOWNLOAD_TOKEN_SECRET=' "$ENV_FILE"; then printf 'TV_DOWNLOAD_TOKEN_SECRET=%s\n' "$(secret)" >> "$ENV_FILE"; fi
if grep -q '^TV_DOWNLOAD_TOKEN_SECRET=replace-with-a-long-random-token$' "$ENV_FILE"; then sed -i "s/^TV_DOWNLOAD_TOKEN_SECRET=.*/TV_DOWNLOAD_TOKEN_SECRET=$(secret)/" "$ENV_FILE"; fi

set -a; source "$ENV_FILE"; set +a
MEDIA_ROOT="${MEDIA_ROOT:-$MEDIA_ROOT_DEFAULT}"
mkdir -p "$MEDIA_ROOT"/{downloads/incomplete,downloads/complete,library/movies,library/series,subtitles,config,cache,backups}
test -w "$MEDIA_ROOT"

COMPOSE_MEDIA_ROOT="$MEDIA_ROOT"
COMPOSE_ENV_FILE="$ENV_FILE"
if [[ "${DOCKER[0]}" == *.exe && "$MEDIA_ROOT" =~ ^/mnt/([a-zA-Z])/(.*)$ ]]; then
  COMPOSE_MEDIA_ROOT="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
  COMPOSE_ENV_LINUX="$ROOT_DIR/.env.compose"
  sed "s|^MEDIA_ROOT=.*$|MEDIA_ROOT=$COMPOSE_MEDIA_ROOT|" "$ENV_FILE" > "$COMPOSE_ENV_LINUX"
  chmod 600 "$COMPOSE_ENV_LINUX"
  COMPOSE_ENV_FILE="$(wslpath -w "$COMPOSE_ENV_LINUX")"
fi

cd "$ROOT_DIR"
"${DOCKER[@]}" volume create media-stack-postgres-data >/dev/null
"${DOCKER[@]}" volume create media-stack-redis-data >/dev/null
"${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" up -d --build
"${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" ps
"$ROOT_DIR/scripts/configure-services.sh"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT_DIR/scripts/install-host-controller.ps1")"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT_DIR/scripts/auto-configure.ps1")"
touch "$MEDIA_ROOT/config/bootstrap/.bootstrap-complete"
if [[ "$KEEP_RUNNING" != true ]]; then
  "${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" stop
  echo "Setup complete. Media stack is stopped. Start it from Media Control or Docker Desktop."
else
  echo "Setup complete. Media stack is running."
fi
