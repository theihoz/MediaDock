#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
MEDIA_ROOT_DEFAULT=/mnt/d/Media
KEEP_RUNNING=false
REPAIR=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-running) KEEP_RUNNING=true ;;
    --repair) REPAIR=true ;;
    *) echo "Unknown bootstrap argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ "$REPAIR" == true && "$KEEP_RUNNING" == true ]]; then
  echo "--repair restores the previous stack state and cannot use --keep-running." >&2
  exit 2
fi

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

MEDIA_ROOT="$MEDIA_ROOT_DEFAULT"
while IFS='=' read -r name value; do
  if [[ "$name" == MEDIA_ROOT && -n "$value" ]]; then MEDIA_ROOT="$value"; break; fi
done < "$ENV_FILE"
mkdir -p "$MEDIA_ROOT"/{downloads/incomplete,downloads/complete,library/movies,library/series,subtitles,config,cache,backups}
test -w "$MEDIA_ROOT"

WINDOWS_MEDIA_ROOT="$(wslpath -w "$MEDIA_ROOT")"
COMPOSE_MEDIA_ROOT="$(wslpath -m "$MEDIA_ROOT")"
COMPOSE_ENV_LINUX="$ROOT_DIR/.env.compose"
awk -v mediaRoot="$COMPOSE_MEDIA_ROOT" '
  BEGIN { root = 0; dockerRoot = 0 }
  /^MEDIA_ROOT=/ { if (!root++) print "MEDIA_ROOT=" mediaRoot; next }
  /^MEDIA_ROOT_DOCKER=/ { if (!dockerRoot++) print "MEDIA_ROOT_DOCKER=" mediaRoot; next }
  { print }
  END {
    if (!root) print "MEDIA_ROOT=" mediaRoot
    if (!dockerRoot) print "MEDIA_ROOT_DOCKER=" mediaRoot
  }
' "$ENV_FILE" > "$COMPOSE_ENV_LINUX"
chmod 600 "$COMPOSE_ENV_LINUX"
COMPOSE_ENV_FILE="$COMPOSE_ENV_LINUX"
if [[ "${DOCKER[0]}" == *.exe ]]; then COMPOSE_ENV_FILE="$(wslpath -w "$COMPOSE_ENV_LINUX")"; fi

cd "$ROOT_DIR"
WAS_RUNNING=false
if [[ "$REPAIR" == true && -n "$("${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" ps --status running --services)" ]]; then
  WAS_RUNNING=true
fi
RESTORE_STOPPED=false
if [[ "$REPAIR" == true && "$WAS_RUNNING" != true ]]; then RESTORE_STOPPED=true; fi
restore_state() {
  status=$?
  trap - EXIT
  if [[ "$RESTORE_STOPPED" == true ]]; then
    "${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" stop >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap restore_state EXIT

"${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" up -d --build --remove-orphans
"${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" ps
"$ROOT_DIR/scripts/configure-services.sh"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT_DIR/scripts/install-host-controller.ps1")"
if [[ "$REPAIR" == true ]]; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT_DIR/scripts/auto-configure.ps1")" -MediaRoot "$WINDOWS_MEDIA_ROOT"
else
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$ROOT_DIR/scripts/auto-configure.ps1")" -MediaRoot "$WINDOWS_MEDIA_ROOT" -FirstRun
  touch "$MEDIA_ROOT/config/bootstrap/.bootstrap-complete"
fi
if [[ "$REPAIR" == true && "$WAS_RUNNING" != true ]] || [[ "$REPAIR" != true && "$KEEP_RUNNING" != true ]]; then
  "${DOCKER[@]}" compose --env-file "$COMPOSE_ENV_FILE" stop
  RESTORE_STOPPED=false
  echo "Setup complete. Media stack is stopped. Start it from Media Control or Docker Desktop."
else
  echo "Setup complete. Media stack is running."
fi
trap - EXIT
