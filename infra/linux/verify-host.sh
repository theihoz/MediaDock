#!/usr/bin/env bash
set -uo pipefail

failures=0

pass() { printf 'PASS %s %s\n' "$1" "${2:-}"; }
fail() { printf 'FAIL %s %s\n' "$1" "${2:-}" >&2; failures=$((failures + 1)); }

source /etc/os-release
[[ ${VERSION_ID:-} == 24.04 ]] && pass os "$PRETTY_NAME" || fail os "expected Ubuntu 24.04, found ${PRETTY_NAME:-unknown}"

pid1=$(ps -p 1 -o comm= 2>/dev/null | xargs)
[[ $pid1 == systemd ]] && pass systemd "$pid1" || fail systemd "PID 1 is $pid1"

if [[ -d /mnt/d/Media ]] && touch /mnt/d/Media/.wsl-media-write-probe 2>/dev/null; then
  rm -f /mnt/d/Media/.wsl-media-write-probe
  pass storage '/mnt/d/Media writable'
else
  fail storage '/mnt/d/Media is not writable'
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
  pass docker "$docker_root"
else
  fail docker 'Docker Engine is not available'
fi

if docker compose version >/dev/null 2>&1; then
  pass compose "$(docker compose version --short)"
else
  fail compose 'Docker Compose plugin is not available'
fi

if nvidia-smi >/dev/null 2>&1; then
  gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
  pass nvidia "$gpu"
else
  fail nvidia 'nvidia-smi is not available in WSL'
fi

if [[ ${VERIFY_GPU_CONTAINER:-0} == 1 ]]; then
  if docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1; then
    pass nvidia-container 'GPU visible inside Docker'
  else
    fail nvidia-container 'GPU is not visible inside Docker'
  fi
fi

(( failures == 0 ))
