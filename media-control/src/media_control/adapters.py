from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any

import httpx
import yaml


def configure_bazarr_provider(path: Path, implementation: str, settings: dict[str, Any]) -> None:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    section_name = implementation.casefold()
    if section_name not in document or not isinstance(document[section_name], dict):
        raise ValueError("Unknown Bazarr provider implementation")
    unknown = set(settings) - set(document[section_name])
    if unknown:
        raise ValueError(f"Unknown provider settings: {', '.join(sorted(unknown))}")
    document[section_name].update(settings)
    enabled = document.setdefault("general", {}).setdefault("enabled_providers", [])
    if section_name not in enabled:
        enabled.append(section_name)
    path.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8")
    os.chmod(path, 0o600)


class ServiceAdapter:
    name = "service"
    base_url = "http://service"
    health_path = "/"
    api_prefix = ""

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str = "",
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self.base_url = (base_url or self.base_url).rstrip("/")
        self.api_key = api_key
        headers = {"Accept": "application/json"}
        if api_key:
            headers["X-Api-Key"] = api_key
        self.client = httpx.Client(
            base_url=self.base_url, headers=headers, timeout=4, transport=transport
        )

    def health(self) -> dict[str, Any]:
        started = time.perf_counter()
        try:
            response = self.client.get(self.health_path)
            if response.status_code >= 400:
                response.raise_for_status()
            return {
                "name": self.name,
                "state": "healthy",
                "latency_ms": round((time.perf_counter() - started) * 1000),
            }
        except Exception as error:
            return {
                "name": self.name,
                "state": "degraded",
                "message": f"{type(error).__name__}: service request failed",
            }


class JellyfinAdapter(ServiceAdapter):
    name = "jellyfin"
    base_url = "http://jellyfin:8096"
    health_path = "/health"


class SeerrAdapter(ServiceAdapter):
    name = "seerr"
    base_url = "http://jellyseerr:5055"
    health_path = "/api/v1/status"

    def search(self, query: str) -> list[dict[str, Any]]:
        response = self.client.get("/api/v1/search", params={"query": query})
        response.raise_for_status()
        items = []
        for raw in response.json().get("results", []):
            media_type = raw.get("mediaType")
            if media_type not in {"movie", "tv"}:
                continue
            title = raw.get("title") or raw.get("name") or "Untitled"
            date = raw.get("releaseDate") or raw.get("firstAirDate") or ""
            items.append({
                "id": f"seerr-{media_type}-{raw['id']}",
                "external_id": f"tmdb:{raw['id']}",
                "media_type": media_type,
                "title": title,
                "year": int(date[:4]) if len(date) >= 4 and date[:4].isdigit() else None,
                "status": "available" if raw.get("mediaInfo") else "not_requested",
                "monitored": False,
                "poster_url": raw.get("posterPath"),
            })
        return items

    def create_request(self, media_type: str, external_id: str, quality: str) -> dict[str, Any]:
        media_id = int(external_id.split(":")[-1])
        payload: dict[str, Any] = {"mediaType": media_type, "mediaId": media_id}
        if quality == "4k":
            # This server intentionally keeps one Arr instance per media type.
            # Override the quality profile for this title instead of pretending
            # that a second, separate 4K Arr instance exists.
            payload.update({
                "is4k": False,
                "profileId": 5,
                "rootFolder": "/data/library/movies" if media_type == "movie"
                else "/data/library/tv",
            })
        response = self.client.post("/api/v1/request", json=payload)
        if response.status_code not in {200, 201, 409}:
            response.raise_for_status()
        return response.json() if response.content else {}


class ServarrAdapter(ServiceAdapter):
    api_prefix = "/api/v3"
    health_path = "/api/v3/health"

    def get(self, resource: str) -> Any:
        response = self.client.get(f"{self.api_prefix}/{resource.lstrip('/')}")
        response.raise_for_status()
        return response.json()

    def command(self, name: str, **payload: Any) -> Any:
        response = self.client.post(f"{self.api_prefix}/command", json={"name": name, **payload})
        response.raise_for_status()
        return response.json()

    def post(self, resource: str, payload: dict[str, Any]) -> Any:
        response = self.client.post(f"{self.api_prefix}/{resource.lstrip('/')}", json=payload)
        response.raise_for_status()
        return response.json() if response.content else {}

    def put(self, resource: str, payload: dict[str, Any]) -> Any:
        response = self.client.put(f"{self.api_prefix}/{resource.lstrip('/')}", json=payload)
        response.raise_for_status()
        return response.json() if response.content else {}

    def delete_media(self, resource: str, item_id: int) -> None:
        response = self.client.delete(
            f"{self.api_prefix}/{resource}/{item_id}",
            params={"deleteFiles": "true", "addImportListExclusion": "false"},
        )
        response.raise_for_status()


class RadarrAdapter(ServarrAdapter):
    name = "radarr"
    base_url = "http://radarr:7878"


class SonarrAdapter(ServarrAdapter):
    name = "sonarr"
    base_url = "http://sonarr:8989"


class LidarrAdapter(ServarrAdapter):
    name = "lidarr"
    base_url = "http://lidarr:8686"
    api_prefix = "/api/v1"
    health_path = "/api/v1/health"


class ProwlarrAdapter(ServarrAdapter):
    name = "prowlarr"
    base_url = "http://prowlarr:9696"
    api_prefix = "/api/v1"
    health_path = "/api/v1/health"


class BazarrAdapter(ServiceAdapter):
    name = "bazarr"
    base_url = "http://bazarr:6767"
    health_path = "/api/system/status"

    def _get_data(self, path: str) -> list[dict[str, Any]]:
        response = self.client.get(path, params={"start": 0, "length": 1000})
        response.raise_for_status()
        return response.json().get("data", [])

    @staticmethod
    def _missing_codes(raw: dict[str, Any]) -> set[str]:
        values = raw.get("missing_subtitles") or []
        return {
            str(item.get("code2") or item.get("language") or "")
            if isinstance(item, dict)
            else str(item)
            for item in values
        }

    def subtitle_items(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        for raw in self._get_data("/api/movies/wanted"):
            missing = self._missing_codes(raw)
            radarr_id = raw.get("radarrId") or raw.get("radarrid")
            items.append({
                "id": f"movie:{radarr_id}", "media_id": f"movie-{radarr_id}",
                "media_type": "movie", "title": raw.get("title", "Movie"),
                "vietnamese": "vi" not in missing, "english": "en" not in missing,
                "state": "missing" if missing else "available",
            })
        for raw in self._get_data("/api/episodes/wanted"):
            missing = self._missing_codes(raw)
            series_id = raw.get("sonarrSeriesId") or raw.get("seriesId")
            episode_id = raw.get("sonarrEpisodeId") or raw.get("episodeId")
            items.append({
                "id": f"episode:{series_id}:{episode_id}",
                "media_id": f"tv-{series_id}", "media_type": "tv",
                "title": raw.get("seriesTitle") or raw.get("title") or "Episode",
                "vietnamese": "vi" not in missing, "english": "en" not in missing,
                "state": "missing" if missing else "available",
            })
        return items

    def subtitle_action(self, item_id: str, action: str) -> None:
        parts = item_id.split(":")
        if parts[0] == "movie" and len(parts) == 2:
            if action == "search":
                response = self.client.patch("/api/movies/subtitles", params={
                    "radarrid": parts[1], "language": "vi",
                    "forced": "false", "hi": "false",
                })
            else:
                response = self.client.patch(
                    "/api/movies", params={"radarrid": parts[1], "action": "scan-disk"}
                )
        elif parts[0] == "episode" and len(parts) == 3:
            if action == "search":
                response = self.client.patch("/api/episodes/subtitles", params={
                    "seriesid": parts[1], "episodeid": parts[2], "language": "vi",
                    "forced": "false", "hi": "false",
                })
            else:
                response = self.client.patch(
                    "/api/series", params={"seriesid": parts[1], "action": "scan-disk"}
                )
        else:
            raise ValueError("Invalid subtitle target")
        response.raise_for_status()

    def configure_provider(self, implementation: str, settings: dict[str, Any]) -> None:
        configure_bazarr_provider(
            Path("/service-config/bazarr/config/config.yaml"), implementation, settings
        )
        response = self.client.post("/api/providers", params={"action": "reset"})
        response.raise_for_status()


class QBittorrentAdapter(ServiceAdapter):
    name = "qbittorrent"
    base_url = "http://qbittorrent:8081"
    health_path = "/"

    def __init__(self, *args: Any, username: str = "admin", password: str = "", **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.username = username
        self.password = password

    def _login(self) -> None:
        if not self.password:
            return
        response = self.client.post(
            "/api/v2/auth/login", data={"username": self.username, "password": self.password}
        )
        if response.status_code not in {200, 204}:
            response.raise_for_status()

    def jobs(self) -> list[dict[str, Any]]:
        self._login()
        response = self.client.get("/api/v2/torrents/info")
        response.raise_for_status()
        return response.json()

    def action(self, torrent_hash: str, action: str) -> None:
        self._login()
        endpoint = {"pause": "stop", "resume": "start", "retry": "recheck", "cancel": "delete"}[action]
        data = {"hashes": torrent_hash}
        if action == "cancel":
            data["deleteFiles"] = "true"
        response = self.client.post(f"/api/v2/torrents/{endpoint}", data=data)
        response.raise_for_status()


class SabnzbdAdapter(ServiceAdapter):
    name = "sabnzbd"
    base_url = "http://sabnzbd:8080"
    health_path = "/api?mode=version&output=json"

    def health(self) -> dict[str, Any]:
        if self.api_key:
            self.health_path = f"/api?mode=version&output=json&apikey={self.api_key}"
        return super().health()

    def jobs(self) -> list[dict[str, Any]]:
        response = self.client.get("/api", params={"mode": "queue", "output": "json", "apikey": self.api_key})
        response.raise_for_status()
        return response.json().get("queue", {}).get("slots", [])

    def action(self, job_id: str, action: str) -> None:
        params = {"output": "json", "apikey": self.api_key}
        if action == "pause":
            params |= {"mode": "queue", "name": "pause", "value": job_id}
        elif action in {"resume", "retry"}:
            params |= {"mode": "queue", "name": "resume", "value": job_id}
        else:
            params |= {"mode": "queue", "name": "delete", "value": job_id, "del_files": "1"}
        response = self.client.get("/api", params=params)
        response.raise_for_status()


class AutobrrAdapter(ServiceAdapter):
    name = "autobrr"
    base_url = "http://autobrr:7474"
    health_path = "/api/healthz/liveness"


class FlareSolverrAdapter(ServiceAdapter):
    name = "flaresolverr"
    base_url = "http://flaresolverr:8191"
    health_path = "/health"


class CleanuparrAdapter(ServiceAdapter):
    name = "cleanuparr"
    base_url = "http://cleanuparr:11011"
    health_path = "/health"


class WizarrAdapter(ServiceAdapter):
    name = "wizarr"
    base_url = "http://wizarr:5690"
    health_path = "/"
