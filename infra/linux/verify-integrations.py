#!/usr/bin/env python3
"""Verify local integration prerequisites without printing secrets."""

import json
import re
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

STACK = Path("/srv/media-stack")
APPDATA = STACK / "appdata"


def key(service):
    return ET.parse(APPDATA / service / "config.xml").getroot().findtext("ApiKey")


def roots(service, port, api_version=3):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/v{api_version}/rootfolder")
    req.add_header("X-Api-Key", key(service))
    with urllib.request.urlopen(req, timeout=10) as response:
        return {row["path"] for row in json.load(response)}


def api_rows(service, port, resource, api_version=3):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/v{api_version}/{resource}"
    )
    req.add_header("X-Api-Key", key(service))
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


def sab_key():
    contents = (APPDATA / "sabnzbd" / "sabnzbd.ini").read_text(encoding="utf-8")
    match = re.search(r"^api_key\s*=\s*(\S+)\s*$", contents, flags=re.MULTILINE)
    assert match
    return match.group(1)


assert "/data/library/movies" in roots("radarr", 7878)
assert "/data/library/tv" in roots("sonarr", 8989)
assert "/data/library/music" in roots("lidarr", 8686, api_version=1)
encoding = ET.parse(APPDATA / "jellyfin" / "config" / "config" / "encoding.xml").getroot()
assert encoding.findtext("HardwareAccelerationType") == "nvenc"
for service, port, version in (
    ("radarr", 7878, 3),
    ("sonarr", 8989, 3),
    ("lidarr", 8686, 1),
):
    clients = api_rows(service, port, "downloadclient", version)
    assert {row["implementation"] for row in clients} >= {"QBittorrent", "Sabnzbd"}

apps = api_rows("prowlarr", 9696, "applications", 1)
assert {row["implementation"] for row in apps} >= {"Radarr", "Sonarr", "Lidarr"}
proxies = api_rows("prowlarr", 9696, "indexerproxy", 1)
assert any(row["implementation"] == "FlareSolverr" for row in proxies)

bazarr = (APPDATA / "bazarr" / "config" / "config.yaml").read_text(encoding="utf-8")
assert re.search(r"(?ms)^radarr:.*?^  ip: \"radarr\"$", bazarr)
assert re.search(r"(?ms)^sonarr:.*?^  ip: \"sonarr\"$", bazarr)

sab_url = (
    "http://127.0.0.1:8085/api?mode=get_cats&output=json&apikey=" + sab_key()
)
with urllib.request.urlopen(sab_url, timeout=10) as response:
    categories = set(json.load(response)["categories"])
assert categories >= {"movies", "tv", "music"}

report = (STACK / "configuration-status.json").read_text(encoding="utf-8")
assert not re.search(r"(?i)(password|api[_-]?key)\s*[=:]", report)
print("PASS local media integrations")
