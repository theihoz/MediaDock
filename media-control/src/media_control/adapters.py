from __future__ import annotations

import time
from typing import Any

import httpx


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
            payload["is4k"] = True
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
