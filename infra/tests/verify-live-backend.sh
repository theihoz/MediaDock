#!/usr/bin/env bash
set -euo pipefail

stack=${1:-/srv/media-stack}
control_token=$(cat "$stack/secrets/media-control.token")

[[ $(stat -c %a "$stack/secrets/media-control.token") == 600 ]]
[[ $(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:11444/v1/status) == 401 ]]

status=$(curl -fsS -H "Authorization: Bearer $control_token" http://127.0.0.1:11444/v1/status)
jq -e '.service_count == 13 and .healthy_services == 13' <<<"$status" >/dev/null

subtitles=$(curl -fsS -H "Authorization: Bearer $control_token" http://127.0.0.1:11444/v1/subtitles)
jq -e '.items | type == "array"' <<<"$subtitles" >/dev/null

profiles=$(curl -fsS -H "Authorization: Bearer $control_token" http://127.0.0.1:11444/v1/admin/profiles)
jq -e '[.items[] | select(.service == "radarr" or .service == "sonarr") | .items[] | select(.id == 5)] | length == 2' <<<"$profiles" >/dev/null

port_bindings=$(docker inspect media-control --format '{{json .HostConfig.PortBindings}}')
jq -e '.["11444/tcp"] == [{"HostIp":"127.0.0.1","HostPort":"11444"}]' <<<"$port_bindings" >/dev/null

bazarr_mount=$(docker inspect media-control --format '{{range .Mounts}}{{if eq .Destination "/service-config/bazarr/config"}}{{.RW}}{{end}}{{end}}')
[[ $bazarr_mount == true ]]

echo 'PASS live backend: 13/13 healthy, authenticated, loopback-only, Ultra-HD profiles present, Bazarr config writable'
