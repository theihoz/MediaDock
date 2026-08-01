#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "deploy-stack-files.sh must run as root" >&2
  exit 1
fi

source_root=${1:?Usage: deploy-stack-files.sh /path/to/infra}
compose_source="$source_root/compose/compose.yaml"
env_generator="$source_root/linux/generate-runtime-env.sh"
compose_verifier="$source_root/tests/verify-compose.sh"
for required in "$compose_source" "$env_generator" "$compose_verifier"; do
  [[ -f $required ]] || { echo "Required source file missing: $required" >&2; exit 1; }
done

install -d -o media -g media -m 0750 /srv/media-stack/appdata /srv/media-stack/scripts
for service in jellyfin seerr radarr sonarr lidarr prowlarr bazarr qbittorrent sabnzbd autobrr flaresolverr cleanuparr wizarr; do
  install -d -o media -g media -m 0750 "/srv/media-stack/appdata/$service"
done
install -d -o media -g media -m 0750 /srv/media-stack/appdata/jellyfin/config /srv/media-stack/appdata/jellyfin/cache

install -o media -g media -m 0640 "$compose_source" /srv/media-stack/compose.yaml
install -o root -g root -m 0755 "$env_generator" /srv/media-stack/scripts/generate-runtime-env.sh
install -o root -g root -m 0755 "$compose_verifier" /srv/media-stack/scripts/verify-compose.sh
/srv/media-stack/scripts/generate-runtime-env.sh /srv/media-stack/.env

cd /srv/media-stack
runuser -u media -- docker compose --env-file .env -f compose.yaml config --quiet
echo 'PASS deployed Compose files and runtime environment'
