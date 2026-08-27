#!/usr/bin/env bash
# Idempotent post-start configuration. Secrets stay in .env and are never printed.
set -Eeuo pipefail

wait_for() {
  local name="$1" url="$2"
  for _ in $(seq 1 30); do curl -fsS --max-time 3 "$url" >/dev/null && return 0; sleep 2; done
  printf '%s\n' "$name unavailable" >&2; return 1
}

required=(qbittorrent prowlarr radarr sonarr bazarr jellyfin)
endpoints=(
  http://localhost:8080
  http://localhost:9696
  http://localhost:7878
  http://localhost:8989
  http://localhost:6767
  http://localhost:8096
)
required_failed=0
for index in "${!required[@]}"; do
  name="${required[$index]}"
  wait_for "$name" "${endpoints[$index]}" || required_failed=1
done
if ! curl -fsS --max-time 3 http://localhost:5055 >/dev/null; then
  printf '%s\n' 'Seerr is optional and remains available for manual setup.' >&2
fi
(( required_failed == 0 )) || exit 1
