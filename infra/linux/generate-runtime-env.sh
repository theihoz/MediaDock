#!/usr/bin/env bash
set -euo pipefail

target=${1:-/srv/media-stack/.env}
if [[ -s $target ]]; then
  echo "PASS preserved existing runtime environment: $target"
  exit 0
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "generate-runtime-env.sh must run as root" >&2
  exit 1
fi

secret() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

umask 077
cat >"$target" <<EOF
COMPOSE_PROJECT_NAME=media
TZ=Asia/Ho_Chi_Minh
PUID=1000
PGID=1000
MEDIA_ADMIN_USER=mediaadmin
MEDIA_ADMIN_PASSWORD=$(secret)
QBITTORRENT_PASSWORD=$(secret)
SABNZBD_PASSWORD=$(secret)
AUTOBRR_SESSION_SECRET=$(secret)
EOF
chown media:media "$target"
chmod 0600 "$target"
echo "PASS generated runtime environment: $target"
