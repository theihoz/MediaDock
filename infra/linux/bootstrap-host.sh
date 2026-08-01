#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "bootstrap-host.sh must run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq

for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    apt-get remove -y "$package"
  fi
done

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
source /etc/os-release
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
systemctl enable --now containerd
usermod --append --groups docker media

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
  gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  >/etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

install -d -o media -g media -m 0750 /srv/media-stack
install -d -o media -g media -m 0750 /srv/media-stack/appdata
install -d -o media -g media -m 0700 /srv/media-stack/secrets
install -d -o media -g media -m 0750 /srv/media-stack/scripts

media_directories=(
  /mnt/d/Media/downloads/torrents/movies
  /mnt/d/Media/downloads/torrents/tv
  /mnt/d/Media/downloads/torrents/music
  /mnt/d/Media/downloads/usenet/incomplete
  /mnt/d/Media/downloads/usenet/complete/movies
  /mnt/d/Media/downloads/usenet/complete/tv
  /mnt/d/Media/downloads/usenet/complete/music
  /mnt/d/Media/library/movies
  /mnt/d/Media/library/tv
  /mnt/d/Media/library/music
)
for directory in "${media_directories[@]}"; do
  install -d -o media -g media -m 0755 "$directory"
done

echo 'PASS Docker Engine, Compose, and NVIDIA Container Toolkit installed'
