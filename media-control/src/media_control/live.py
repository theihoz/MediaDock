from __future__ import annotations

import hashlib
import shutil
from pathlib import Path
from typing import Any

from .adapters import (
    AutobrrAdapter, BazarrAdapter, CleanuparrAdapter, FlareSolverrAdapter,
    JellyfinAdapter, LidarrAdapter, ProwlarrAdapter, QBittorrentAdapter,
    RadarrAdapter, SabnzbdAdapter, SeerrAdapter, SonarrAdapter, WizarrAdapter,
)
from .config import bazarr_api_key, qbit_password, sab_api_key, seerr_api_key, xml_api_key
from .hub import MemoryHub
from .models import AdminResource, MediaRequest


class LiveHub(MemoryHub):
    """Normalizes live APIs while allowing unrelated modules to degrade independently."""

    def __init__(self) -> None:
        super().__init__(state_path=Path("/state/admin.json"))
        self.seerr = SeerrAdapter(api_key=seerr_api_key())
        self.radarr = RadarrAdapter(api_key=xml_api_key("radarr"))
        self.sonarr = SonarrAdapter(api_key=xml_api_key("sonarr"))
        self.lidarr = LidarrAdapter(api_key=xml_api_key("lidarr"))
        self.prowlarr = ProwlarrAdapter(api_key=xml_api_key("prowlarr"))
        self.bazarr = BazarrAdapter(api_key=bazarr_api_key())
        self.qbittorrent = QBittorrentAdapter(password=qbit_password())
        self.sabnzbd = SabnzbdAdapter(api_key=sab_api_key())
        self.adapters = [
            JellyfinAdapter(), self.seerr, self.radarr, self.sonarr, self.lidarr,
            self.prowlarr, self.bazarr, self.qbittorrent, self.sabnzbd,
            AutobrrAdapter(), FlareSolverrAdapter(), CleanuparrAdapter(), WizarrAdapter(),
        ]

    def status(self) -> dict[str, Any]:
        health = self.services()
        healthy = sum(item["state"] == "healthy" for item in health)
        return {
            "state": "healthy" if healthy == len(health) else "degraded",
            "wsl": "running", "docker": "running",
            "gpu": "available", "healthy_services": healthy, "service_count": len(health),
        }

    def services(self) -> list[dict[str, Any]]:
        return [adapter.health() for adapter in self.adapters]

    def storage(self) -> dict[str, Any]:
        usage = shutil.disk_usage("/data")
        return {"mount": "/data", "total_bytes": usage.total, "free_bytes": usage.free,
                "used_percent": round(usage.used / usage.total * 100, 2)}

    def search(self, query: str) -> list[dict[str, Any]]:
        return self.seerr.search(query)

    def request(self, request: MediaRequest) -> tuple[dict[str, Any], bool]:
        key = f"{request.media_type}:{request.external_id}:{request.quality}"
        operation_id = hashlib.sha256(key.encode()).hexdigest()[:16]
        changed = key not in self.requests
        if changed:
            self.seerr.create_request(request.media_type, request.external_id, request.quality)
            self.requests[key] = request.model_dump()
            self._save_admin()
        return {"operation_id": operation_id, "changed": changed, "state": "accepted",
                "message": "Yêu cầu đã được chuyển tới Seerr"}, changed

    def library(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        for adapter, resource, media_type, title_field in [
            (self.radarr, "movie", "movie", "title"),
            (self.sonarr, "series", "tv", "title"),
            (self.lidarr, "artist", "music", "artistName"),
        ]:
            try:
                for raw in adapter.get(resource):
                    item_id = f"{media_type}-{raw['id']}"
                    items.append({"id": item_id, "external_id": str(raw.get("tmdbId") or raw.get("tvdbId") or raw.get("foreignArtistId") or ""),
                                  "media_type": media_type, "title": raw.get(title_field, "Untitled"),
                                  "year": raw.get("year"), "status": raw.get("status", "available"),
                                  "monitored": raw.get("monitored", True)})
            except Exception:
                continue
        return items

    def delete_library(self, item_id: str) -> bool:
        try:
            media_type, raw_id = item_id.rsplit("-", 1)
            adapter, resource = {
                "movie": (self.radarr, "movie"),
                "tv": (self.sonarr, "series"),
                "music": (self.lidarr, "artist"),
            }[media_type]
            adapter.delete_media(resource, int(raw_id))
            return True
        except (KeyError, ValueError):
            return False

    def downloads(self) -> list[dict[str, Any]]:
        jobs: list[dict[str, Any]] = []
        try:
            for raw in self.qbittorrent.jobs():
                jobs.append({"id": f"qbittorrent:{raw['hash']}", "client": "qbittorrent",
                             "title": raw.get("name", "Torrent"), "progress": raw.get("progress", 0),
                             "state": raw.get("state", "unknown"), "speed_bytes": raw.get("dlspeed", 0),
                             "eta_seconds": raw.get("eta")})
        except Exception:
            pass
        try:
            for raw in self.sabnzbd.jobs():
                percentage = float(raw.get("percentage", 0)) / 100
                jobs.append({"id": f"sabnzbd:{raw['nzo_id']}", "client": "sabnzbd",
                             "title": raw.get("filename", "Usenet"), "progress": percentage,
                             "state": raw.get("status", "unknown"), "speed_bytes": 0,
                             "eta_seconds": None})
        except Exception:
            pass
        return jobs

    def subtitles(self) -> list[dict[str, Any]]:
        try:
            return self.bazarr.subtitle_items()
        except Exception:
            return []

    def operation(self, scope: str, target: str, action: str) -> dict[str, Any]:
        if scope == "download" and ":" in target:
            client, job_id = target.split(":", 1)
            (self.qbittorrent if client == "qbittorrent" else self.sabnzbd).action(job_id, action)
        elif scope == "stack" and action == "scan":
            self.radarr.command("RescanMovie")
            self.sonarr.command("RescanSeries")
            self.lidarr.command("RescanFolders")
        elif scope == "subtitle":
            self.bazarr.subtitle_action(target, action)
        return super().operation(scope, target, action)

    @staticmethod
    def _schema_payload(
        schemas: list[dict[str, Any]], resource: AdminResource,
        ignored_settings: set[str] | None = None,
    ) -> dict[str, Any]:
        ignored = ignored_settings or set()
        schema = next(
            (item for item in schemas if item.get("implementation", "").casefold()
             == resource.implementation.casefold()),
            None,
        )
        if schema is None:
            raise ValueError(f"Unknown implementation: {resource.implementation}")
        payload = dict(schema)
        payload["name"] = resource.name
        payload["enable"] = resource.enabled
        payload["fields"] = [dict(field) for field in schema.get("fields", [])]
        known = {field.get("name"): field for field in payload["fields"]}
        unknown = set(resource.settings) - set(known) - ignored
        if unknown:
            raise ValueError(f"Unknown settings: {', '.join(sorted(unknown))}")
        for name, value in resource.settings.items():
            if name not in ignored:
                known[name]["value"] = value
        return payload

    @staticmethod
    def _update_payload(
        existing: dict[str, Any], settings: dict[str, Any], ignored: set[str] | None = None,
    ) -> tuple[dict[str, Any], bool]:
        ignored = ignored or set()
        payload = dict(existing)
        payload["fields"] = [dict(field) for field in existing.get("fields", [])]
        known = {field.get("name"): field for field in payload["fields"]}
        unknown = set(settings) - set(known) - ignored
        if unknown:
            raise ValueError(f"Unknown settings: {', '.join(sorted(unknown))}")
        changed = False
        for name, value in settings.items():
            if name not in ignored and known[name].get("value") != value:
                known[name]["value"] = value
                changed = True
        return payload, changed

    def upsert_admin(self, kind: str, resource: AdminResource) -> tuple[dict[str, Any], bool]:
        if kind == "providers":
            key = resource.id or f"{resource.implementation}:{resource.name.casefold()}"
            desired = resource.model_copy(update={"id": key}).model_dump()
            if self.admin[kind].get(key) != desired:
                self.bazarr.configure_provider(resource.implementation, resource.settings)
        elif kind == "indexers" and any(resource.settings.values()):
            current = self.prowlarr.get("indexer")
            existing = next((item for item in current if
                             item.get("name", "").casefold() == resource.name.casefold()
                             and item.get("implementation", "").casefold()
                             == resource.implementation.casefold()), None)
            if existing:
                payload, changed = self._update_payload(existing, resource.settings)
                if changed:
                    self.prowlarr.put(f"indexer/{existing['id']}", payload)
            else:
                payload = self._schema_payload(self.prowlarr.get("indexer/schema"), resource)
                self.prowlarr.post("indexer", payload)
        elif kind == "clients" and resource.implementation.casefold() != "integration":
            service_name = str(resource.settings.get("service", "")).casefold()
            service = {"radarr": self.radarr, "sonarr": self.sonarr, "lidarr": self.lidarr}.get(service_name)
            if service is None:
                raise ValueError("Download client requires service=radarr, sonarr, or lidarr")
            current = service.get("downloadclient")
            existing = next((item for item in current if
                             item.get("implementation", "").casefold()
                             == resource.implementation.casefold()), None)
            if existing:
                payload, changed = self._update_payload(
                    existing, resource.settings, {"service"}
                )
                if changed:
                    service.put(f"downloadclient/{existing['id']}", payload)
            else:
                payload = self._schema_payload(
                    service.get("downloadclient/schema"), resource, {"service"}
                )
                service.post("downloadclient", payload)
        elif kind == "profiles" and resource.implementation.casefold() == "rootfolder":
            for service, setting in (
                (self.radarr, "movies"), (self.sonarr, "tv"), (self.lidarr, "music")
            ):
                path = resource.settings.get(setting)
                if path and not any(item.get("path") == path for item in service.get("rootfolder")):
                    service.post("rootfolder", {"path": path})
        return super().upsert_admin(kind, resource)

    def list_admin(self, kind: str) -> list[dict[str, Any]]:
        try:
            if kind == "indexers":
                return self.prowlarr.get("indexer")
            if kind == "profiles":
                return [{"service": service.name, "items": service.get("qualityprofile")}
                        for service in (self.radarr, self.sonarr, self.lidarr)]
            if kind == "clients":
                return [{"service": service.name, "items": service.get("downloadclient")}
                        for service in (self.radarr, self.sonarr, self.lidarr)]
        except Exception:
            return []
        return super().list_admin(kind)
