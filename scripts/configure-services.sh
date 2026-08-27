#!/usr/bin/env bash
# Idempotent post-start configuration. Secrets stay in .env and are never printed.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${MEDIA_ROOT:-/mnt/d/Media}/config/bootstrap"
mkdir -p "$STATE_DIR"

wait_for() {
  local name="$1" url="$2"
  for _ in $(seq 1 30); do curl -fsS --max-time 3 "$url" >/dev/null && return 0; sleep 2; done
  printf '%s\n' "$name unavailable" >&2; return 1
}

declare -A endpoints=(
  [qbittorrent]=http://localhost:8080
  [prowlarr]=http://localhost:9696
  [radarr]=http://localhost:7878
  [sonarr]=http://localhost:8989
  [bazarr]=http://localhost:6767
  [jellyfin]=http://localhost:8096
  [seerr]=http://localhost:5055
)

printf '{"configuredAt":"%s","services":{' "$(date -Is)" > "$STATE_DIR/state.json"
first=1
for name in "${!endpoints[@]}"; do
  if wait_for "$name" "${endpoints[$name]}"; then state=ready; else state=failed; fi
  [[ $first == 1 ]] || printf ',' >> "$STATE_DIR/state.json"; first=0
  printf '"%s":"%s"' "$name" "$state" >> "$STATE_DIR/state.json"
done
printf '}}\n' >> "$STATE_DIR/state.json"

cat <<'EOF'
Services are reachable. Complete initial local account setup once, then add the resulting API keys to your private .env and run this script again.
Provider/indexer accounts and subtitle credentials intentionally remain manual because they are provider-specific and must not be guessed or logged.
EOF
