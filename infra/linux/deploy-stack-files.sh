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
media_control_source="$(dirname "$source_root")/media-control"
token_script="$source_root/linux/ensure-media-control-token.sh"
for required in "$compose_source" "$env_generator" "$compose_verifier" "$token_script" "$media_control_source/Dockerfile"; do
  [[ -f $required ]] || { echo "Required source file missing: $required" >&2; exit 1; }
done

install -d -o media -g media -m 0750 /srv/media-stack/appdata /srv/media-stack/scripts
for service in media-control jellyfin seerr radarr sonarr lidarr prowlarr bazarr qbittorrent sabnzbd autobrr flaresolverr cleanuparr wizarr; do
  install -d -o media -g media -m 0750 "/srv/media-stack/appdata/$service"
done
install -d -o media -g media -m 0750 /srv/media-stack/appdata/jellyfin/config /srv/media-stack/appdata/jellyfin/cache

install -o media -g media -m 0640 "$compose_source" /srv/media-stack/compose.yaml
install -o root -g root -m 0755 "$env_generator" /srv/media-stack/scripts/generate-runtime-env.sh
install -o root -g root -m 0755 "$compose_verifier" /srv/media-stack/scripts/verify-compose.sh
install -o root -g root -m 0755 "$token_script" /srv/media-stack/scripts/ensure-media-control-token.sh
rm -rf /srv/media-stack/media-control
cp -a "$media_control_source" /srv/media-stack/media-control
find /srv/media-stack/media-control -type d -exec chmod 0755 {} +
find /srv/media-stack/media-control -type f -exec chmod 0644 {} +
chmod 0755 /srv/media-stack/media-control/docker-entrypoint.sh
/srv/media-stack/scripts/generate-runtime-env.sh /srv/media-stack/.env
/srv/media-stack/scripts/ensure-media-control-token.sh

cd /srv/media-stack
runuser -u media -- docker compose --env-file .env -f compose.yaml config --quiet
echo 'PASS deployed Compose files and runtime environment'
