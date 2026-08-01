#!/usr/bin/env python3
"""Apply idempotent local-only defaults after the web setup wizards."""

from __future__ import annotations

import http.cookiejar
import json
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from copy import deepcopy
from pathlib import Path

STACK = Path("/srv/media-stack")
APPDATA = STACK / "appdata"


def redact(value: str) -> str:
    value = re.sub(r"(?i)(api[_-]?key\s*[=:]\s*[\"']?)[^\s\"']+", r"\1[redacted]", value)
    value = re.sub(r"(?i)(password\s*[=:]\s*[\"']?)[^\s\"']+", r"\1[redacted]", value)
    return value


def set_schema_field(schema: dict, name: str, value) -> None:
    for field in schema.get("fields", []):
        if field.get("name") == name:
            field["value"] = value
            return
    raise KeyError(f"Schema field not found: {name}")


def has_equivalent(records: list[dict], *, name: str, implementation: str) -> bool:
    expected = (name.casefold(), implementation.casefold())
    return any(
        (str(row.get("name", "")).casefold(), str(row.get("implementation", "")).casefold())
        == expected
        for row in records
    )


def build_schema_record(schema: dict, *, name: str, values: dict) -> dict:
    record = deepcopy(schema)
    record["name"] = name
    for field_name, value in values.items():
        set_schema_field(record, field_name, value)
    return record


def api_key(service: str) -> str:
    root = ET.parse(APPDATA / service / "config.xml").getroot()
    value = root.findtext("ApiKey")
    if not value:
        raise RuntimeError(f"Missing API key for {service}")
    return value


def request_json(url: str, key: str, method: str = "GET", payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("X-Api-Key", key)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        detail = redact(exc.read().decode(errors="replace"))
        raise RuntimeError(f"{method} {url} failed ({exc.code}): {detail}") from exc


def read_env() -> dict[str, str]:
    result = {}
    for line in (STACK / ".env").read_text(encoding="utf-8").splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key] = value
    return result


def form_request(opener, url: str, values: dict) -> str:
    body = urllib.parse.urlencode(values).encode()
    request = urllib.request.Request(url, data=body, method="POST")
    with opener.open(request, timeout=15) as response:
        return response.read().decode(errors="replace")


def extract_qbittorrent_password(completed: subprocess.CompletedProcess) -> str | None:
    logs = (completed.stdout or "") + "\n" + (completed.stderr or "")
    matches = re.findall(
        r"temporary password is provided for this session:\s*(\S+)",
        logs,
        flags=re.IGNORECASE,
    )
    return matches[-1] if matches else None


def qbittorrent_login_succeeded(response_body: str) -> bool:
    return response_body.strip() in ("", "Ok.")


def configure_qbittorrent(env: dict[str, str]) -> None:
    base = "http://127.0.0.1:8081"
    passwords = [env["QBITTORRENT_PASSWORD"]]
    completed = subprocess.run(
        ["docker", "logs", "qbittorrent"],
        check=False,
        capture_output=True,
        text=True,
    )
    temporary = extract_qbittorrent_password(completed)
    if temporary:
        passwords.append(temporary)

    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
    )
    for password in passwords:
        try:
            result = form_request(
                opener,
                f"{base}/api/v2/auth/login",
                {"username": "admin", "password": password},
            )
            if qbittorrent_login_succeeded(result):
                break
        except urllib.error.HTTPError:
            continue
    else:
        raise RuntimeError("Could not authenticate to qBittorrent")

    preferences = {
        "save_path": "/data/downloads/torrents",
        "temp_path": "/data/downloads/torrents/incomplete",
        "temp_path_enabled": True,
        "web_ui_username": "admin",
        "web_ui_password": env["QBITTORRENT_PASSWORD"],
        "listen_port": 6881,
        "bypass_local_auth": False,
    }
    form_request(
        opener,
        f"{base}/api/v2/app/setPreferences",
        {"json": json.dumps(preferences)},
    )
    with opener.open(f"{base}/api/v2/torrents/categories", timeout=15) as response:
        categories = json.load(response)
    for name in ("movies", "tv", "music"):
        if name not in categories:
            form_request(
                opener,
                f"{base}/api/v2/torrents/createCategory",
                {"category": name, "savePath": f"/data/downloads/torrents/{name}"},
            )


def parse_sabnzbd_api_key(contents: str) -> str:
    match = re.search(r"^api_key\s*=\s*(\S+)\s*$", contents, flags=re.MULTILINE)
    if not match:
        raise RuntimeError("SABnzbd API key is missing")
    return match.group(1)


def sabnzbd_key() -> str:
    contents = (APPDATA / "sabnzbd" / "sabnzbd.ini").read_text(encoding="utf-8")
    return parse_sabnzbd_api_key(contents)


def sabnzbd_call(key: str, **parameters):
    query = {"output": "json", "apikey": key, **parameters}
    url = "http://127.0.0.1:8085/api?" + urllib.parse.urlencode(query)
    with urllib.request.urlopen(url, timeout=15) as response:
        return json.load(response)


def sabnzbd_misc_settings() -> dict[str, str]:
    return {
        "download_dir": "/data/downloads/usenet/incomplete",
        "complete_dir": "/data/downloads/usenet/complete",
        "host_whitelist": "sabnzbd,localhost,127.0.0.1",
    }


def configure_sabnzbd() -> str:
    key = sabnzbd_key()
    for keyword, value in sabnzbd_misc_settings().items():
        sabnzbd_call(
            key,
            mode="set_config",
            section="misc",
            keyword=keyword,
            value=value,
        )
    existing = set(sabnzbd_call(key, mode="get_cats").get("categories", []))
    for name in ("movies", "tv", "music"):
        if name not in existing:
            sabnzbd_call(
                key,
                mode="set_config",
                section="categories",
                name=name,
                dir=name,
            )
    return key


def ensure_root(
    service: str, port: int, path: str, api_version: int = 3, extra=None
) -> None:
    key = api_key(service)
    url = f"http://127.0.0.1:{port}/api/v{api_version}/rootfolder"
    existing = request_json(url, key)
    if not any(item.get("path") == path for item in existing):
        payload = {"path": path}
        payload.update(extra or {})
        request_json(url, key, "POST", payload)


def ensure_download_client(
    service: str,
    port: int,
    api_version: int,
    category_field: str,
    category: str,
    env: dict[str, str],
    sab_key: str,
) -> None:
    key = api_key(service)
    base = f"http://127.0.0.1:{port}/api/v{api_version}/downloadclient"
    existing = request_json(base, key)
    schemas = request_json(f"{base}/schema", key)
    definitions = (
        (
            "qBittorrent",
            "QBittorrent",
            {
                "host": "qbittorrent",
                "port": 8081,
                "useSsl": False,
                "urlBase": "",
                "username": "admin",
                "password": env["QBITTORRENT_PASSWORD"],
                category_field: category,
            },
        ),
        (
            "SABnzbd",
            "Sabnzbd",
            {
                "host": "sabnzbd",
                "port": 8080,
                "useSsl": False,
                "urlBase": "",
                "apiKey": sab_key,
                "username": "",
                "password": "",
                category_field: category,
            },
        ),
    )
    for name, implementation, values in definitions:
        if has_equivalent(existing, name=name, implementation=implementation):
            continue
        schema = next(row for row in schemas if row.get("implementation") == implementation)
        record = build_schema_record(schema, name=name, values=values)
        record.update(
            {
                "enable": True,
                "priority": 1,
                "removeCompletedDownloads": True,
                "removeFailedDownloads": True,
            }
        )
        request_json(base, key, "POST", record)


def configure_download_clients(env: dict[str, str], sab_key: str) -> None:
    ensure_download_client(
        "radarr", 7878, 3, "movieCategory", "movies", env, sab_key
    )
    ensure_download_client("sonarr", 8989, 3, "tvCategory", "tv", env, sab_key)
    ensure_download_client(
        "lidarr", 8686, 1, "musicCategory", "music", env, sab_key
    )


def ensure_prowlarr_integrations() -> None:
    key = api_key("prowlarr")
    base = "http://127.0.0.1:9696/api/v1"
    apps = request_json(f"{base}/applications", key)
    schemas = request_json(f"{base}/applications/schema", key)
    for name, port, target_key in (
        ("Radarr", 7878, api_key("radarr")),
        ("Sonarr", 8989, api_key("sonarr")),
        ("Lidarr", 8686, api_key("lidarr")),
    ):
        if has_equivalent(apps, name=name, implementation=name):
            continue
        schema = next(row for row in schemas if row.get("implementation") == name)
        record = build_schema_record(
            schema,
            name=name,
            values={
                "prowlarrUrl": "http://prowlarr:9696",
                "baseUrl": f"http://{name.casefold()}:{port}",
                "apiKey": target_key,
                "authUsername": "",
                "authPassword": "",
            },
        )
        record["syncLevel"] = "fullSync"
        record["enable"] = True
        request_json(f"{base}/applications", key, "POST", record)

    proxies = request_json(f"{base}/indexerproxy", key)
    if not has_equivalent(proxies, name="FlareSolverr", implementation="FlareSolverr"):
        proxy_schemas = request_json(f"{base}/indexerproxy/schema", key)
        schema = next(
            row for row in proxy_schemas if row.get("implementation") == "FlareSolverr"
        )
        record = build_schema_record(
            schema,
            name="FlareSolverr",
            values={"host": "http://flaresolverr:8191/", "requestTimeout": 60},
        )
        request_json(f"{base}/indexerproxy", key, "POST", record)


def set_yaml_value(lines: list[str], section: str, key: str, value) -> bool:
    start = next(i for i, line in enumerate(lines) if line == f"{section}:\n")
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i] and not lines[i][0].isspace()),
        len(lines),
    )
    rendered = json.dumps(value) if isinstance(value, str) else str(value).lower()
    prefix = f"  {key}:"
    for index in range(start + 1, end):
        if lines[index].startswith(prefix):
            replacement = f"{prefix} {rendered}\n"
            changed = lines[index] != replacement
            lines[index] = replacement
            return changed
    raise KeyError(f"Bazarr setting not found: {section}.{key}")


def configure_bazarr() -> None:
    path = APPDATA / "bazarr" / "config" / "config.yaml"
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    changed = False
    for section, key, value in (
        ("general", "use_radarr", True),
        ("general", "use_sonarr", True),
        ("radarr", "ip", "radarr"),
        ("radarr", "port", 7878),
        ("radarr", "apikey", api_key("radarr")),
        ("sonarr", "ip", "sonarr"),
        ("sonarr", "port", 8989),
        ("sonarr", "apikey", api_key("sonarr")),
    ):
        changed = set_yaml_value(lines, section, key, value) or changed
    if changed:
        path.write_text("".join(lines), encoding="utf-8")
        subprocess.run(
            ["docker", "restart", "bazarr"], check=True, stdout=subprocess.DEVNULL
        )


def enable_jellyfin_nvenc() -> None:
    path = APPDATA / "jellyfin" / "config" / "config" / "encoding.xml"
    tree = ET.parse(path)
    root = tree.getroot()
    field = root.find("HardwareAccelerationType")
    if field is None:
        field = ET.SubElement(root, "HardwareAccelerationType")
    field.text = "nvenc"
    tree.write(path, encoding="utf-8", xml_declaration=True)
    subprocess.run(["docker", "restart", "jellyfin"], check=True, stdout=subprocess.DEVNULL)


def main() -> None:
    env = read_env()
    ensure_root("radarr", 7878, "/data/library/movies")
    ensure_root("sonarr", 8989, "/data/library/tv")
    ensure_root(
        "lidarr",
        8686,
        "/data/library/music",
        api_version=1,
        extra={
            "name": "Music",
            "defaultMetadataProfileId": 1,
            "defaultQualityProfileId": 1,
        },
    )
    configure_qbittorrent(env)
    sab_key = configure_sabnzbd()
    configure_download_clients(env, sab_key)
    ensure_prowlarr_integrations()
    configure_bazarr()
    enable_jellyfin_nvenc()
    status = {
        "configured": [
            "jellyfin",
            "seerr",
            "radarr",
            "sonarr",
            "lidarr",
            "prowlarr",
            "bazarr",
            "qbittorrent",
            "sabnzbd",
        ],
        "awaiting_external_credentials": [
            "indexers", "trackers", "usenet_provider", "subtitle_provider"
        ],
    }
    (STACK / "configuration-status.json").write_text(
        json.dumps(status, indent=2) + "\n", encoding="utf-8"
    )
    print("Configured media roots and Jellyfin NVIDIA NVENC")


if __name__ == "__main__":
    main()
