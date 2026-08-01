#!/bin/sh
set -eu

token_file=${MEDIA_CONTROL_TOKEN_FILE:-/run/secrets/media-control.token}
if [ ! -r "$token_file" ]; then
  echo 'media-control token file is missing or unreadable' >&2
  exit 1
fi
MEDIA_CONTROL_TOKEN=$(cat "$token_file")
export MEDIA_CONTROL_TOKEN MEDIA_CONTROL_LIVE=1
exec uvicorn media_control.app:app --host 0.0.0.0 --port 11444 --no-access-log
