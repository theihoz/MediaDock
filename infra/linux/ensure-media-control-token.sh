#!/usr/bin/env bash
set -euo pipefail

umask 077
token_dir=/srv/media-stack/secrets
token_file="$token_dir/media-control.token"
qbit_file="$token_dir/qbittorrent.password"
install -d -o media -g media -m 0700 "$token_dir"
if [[ ! -s $token_file ]]; then
  openssl rand -hex 32 >"$token_file"
fi
chown media:media "$token_file"
chmod 0600 "$token_file"
if [[ -f /srv/media-stack/.env ]]; then
  qbit_password=$(sed -n 's/^QBITTORRENT_PASSWORD=//p' /srv/media-stack/.env | head -n 1)
  if [[ -n $qbit_password ]]; then
    printf '%s' "$qbit_password" >"$qbit_file"
    chown media:media "$qbit_file"
    chmod 0600 "$qbit_file"
  fi
fi
echo 'PASS media-control token is present with mode 0600'
