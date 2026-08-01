from __future__ import annotations

import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


CONFIG_ROOT = Path("/service-config")


def xml_api_key(service: str, root: Path = CONFIG_ROOT) -> str:
    path = root / service / "config.xml"
    try:
        return ET.parse(path).findtext("ApiKey", default="")
    except (OSError, ET.ParseError):
        return ""


def seerr_api_key(root: Path = CONFIG_ROOT) -> str:
    try:
        return json.loads((root / "seerr" / "settings.json").read_text())["main"]["apiKey"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        return ""


def bazarr_api_key(root: Path = CONFIG_ROOT) -> str:
    try:
        content = (root / "bazarr" / "config" / "config.yaml").read_text()
    except OSError:
        return ""
    match = re.search(r"(?m)^\s*apikey:\s*['\"]?([^'\"\s]+)", content)
    return match.group(1) if match else ""


def sab_api_key(root: Path = CONFIG_ROOT) -> str:
    try:
        content = (root / "sabnzbd" / "sabnzbd.ini").read_text()
    except OSError:
        return ""
    match = re.search(r"(?m)^api_key\s*=\s*(\S+)", content)
    return match.group(1) if match else ""


def qbit_password(path: Path = Path("/run/secrets/qbittorrent.password")) -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return ""
