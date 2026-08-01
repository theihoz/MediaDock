#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "initialize-wsl.sh must run as root" >&2
  exit 1
fi

if ! getent group 1000 >/dev/null; then
  groupadd --gid 1000 media
elif [[ $(getent group 1000 | cut -d: -f1) != media ]]; then
  echo "GID 1000 already belongs to a non-media group" >&2
  exit 1
fi

if ! getent passwd media >/dev/null; then
  if getent passwd 1000 >/dev/null; then
    echo "UID 1000 already belongs to a non-media user" >&2
    exit 1
  fi
  useradd --create-home --uid 1000 --gid 1000 --shell /bin/bash media
fi

cat >/etc/wsl.conf <<'EOF'
[boot]
systemd=true

[user]
default=media

[automount]
enabled=true
options=metadata,uid=1000,gid=1000,umask=0022,fmask=0011
EOF

echo "PASS initialized WSL user and systemd configuration"
