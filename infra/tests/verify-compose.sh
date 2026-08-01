#!/usr/bin/env bash
set -euo pipefail

compose_file=${1:-/srv/media-stack/compose.yaml}
env_file=${2:-/srv/media-stack/.env}

[[ -f $compose_file ]] || { echo "FAIL compose file missing: $compose_file" >&2; exit 1; }
[[ -f $env_file ]] || { echo "FAIL environment file missing: $env_file" >&2; exit 1; }

config=$(docker compose --env-file "$env_file" -f "$compose_file" config --format json)
expected='["autobrr","bazarr","cleanuparr","flaresolverr","jellyfin","lidarr","prowlarr","qbittorrent","radarr","sabnzbd","seerr","sonarr","wizarr"]'
actual=$(jq -c '.services | keys | sort' <<<"$config")
[[ $actual == "$expected" ]] || { echo "FAIL unexpected services: $actual" >&2; exit 1; }

jq -e '[.services[] | select(.restart != "unless-stopped")] | length == 0' <<<"$config" >/dev/null || {
  echo 'FAIL every service must use restart: unless-stopped' >&2; exit 1;
}
jq -e '.services.flaresolverr.ports == null' <<<"$config" >/dev/null || {
  echo 'FAIL FlareSolverr must not publish a host port' >&2; exit 1;
}
jq -e '.services.qbittorrent.ports[] | select(.published == "8081" and .target == 8081)' <<<"$config" >/dev/null || {
  echo 'FAIL qBittorrent must publish 8081:8081' >&2; exit 1;
}

for service in radarr sonarr lidarr bazarr qbittorrent sabnzbd; do
  jq -e --arg service "$service" '.services[$service].volumes[] | select(.source == "/mnt/d/Media" and .target == "/data")' <<<"$config" >/dev/null || {
    echo "FAIL $service does not share /mnt/d/Media:/data" >&2; exit 1;
  }
done

jq -e '.services.jellyfin.runtime == "nvidia"' <<<"$config" >/dev/null || {
  echo 'FAIL Jellyfin must use the NVIDIA runtime' >&2; exit 1;
}
jq -e '[.services[] | select(.logging.options."max-size" != "10m" or .logging.options."max-file" != "3")] | length == 0' <<<"$config" >/dev/null || {
  echo 'FAIL every service must rotate json-file logs' >&2; exit 1;
}

echo 'PASS compose contract'
