from __future__ import annotations

import hashlib
import json
import os
import shutil
from pathlib import Path
from typing import Any

from .models import AdminResource, MediaRequest
from .security import redact


class MemoryHub:
    """Deterministic hub used by tests and as a safe degraded-mode fallback."""

    def __init__(self, state_path: Path | None = None) -> None:
        self.state_path = state_path
        self.requests: dict[str, dict[str, Any]] = {}
        self.admin: dict[str, dict[str, dict[str, Any]]] = {
            kind: {} for kind in ("indexers", "clients", "profiles", "providers")
        }
        if state_path and state_path.exists():
            loaded = json.loads(state_path.read_text(encoding="utf-8"))
            for kind in self.admin:
                self.admin[kind] = loaded.get(kind, {})
            self.requests = loaded.get("requests", {})
        self.library_items = [
            {
                "id": "movie-1",
                "external_id": "tmdb:329865",
                "media_type": "movie",
                "title": "Arrival",
                "year": 2016,
                "status": "available",
                "monitored": True,
            }
        ]

    def status(self) -> dict[str, Any]:
        return {"state": "healthy", "wsl": "running", "docker": "running", "gpu": "available"}

    def services(self) -> list[dict[str, Any]]:
        names = (
            "jellyfin", "seerr", "radarr", "sonarr", "lidarr", "prowlarr",
            "bazarr", "qbittorrent", "sabnzbd", "autobrr", "flaresolverr",
            "cleanuparr", "wizarr",
        )
        return [{"name": name, "state": "healthy"} for name in names]

    def storage(self) -> dict[str, Any]:
        usage = shutil.disk_usage("/")
        return {
            "mount": "/data",
            "total_bytes": usage.total,
            "free_bytes": usage.free,
            "used_percent": round((usage.used / usage.total) * 100, 2),
        }

    def search(self, query: str) -> list[dict[str, Any]]:
        title = query.strip() or "Arrival"
        digest = hashlib.sha256(title.casefold().encode()).hexdigest()[:10]
        return [{
            "id": f"search-{digest}", "external_id": f"tmdb:{digest}",
            "media_type": "movie", "title": title, "year": None,
            "status": "available", "monitored": False,
        }]

    def request(self, request: MediaRequest) -> tuple[dict[str, Any], bool]:
        key = f"{request.media_type}:{request.external_id}:{request.quality}"
        operation_id = hashlib.sha256(key.encode()).hexdigest()[:16]
        changed = key not in self.requests
        self.requests.setdefault(key, request.model_dump())
        if changed:
            self._save_admin()
        return {
            "operation_id": operation_id, "changed": changed,
            "state": "accepted", "message": "Yêu cầu đã được ghi nhận",
        }, changed

    def library(self) -> list[dict[str, Any]]:
        return list(self.library_items)

    def delete_library(self, item_id: str) -> bool:
        before = len(self.library_items)
        self.library_items = [item for item in self.library_items if item["id"] != item_id]
        return len(self.library_items) != before

    def downloads(self) -> list[dict[str, Any]]:
        return []

    def subtitles(self) -> list[dict[str, Any]]:
        return []

    def operation(self, scope: str, target: str, action: str) -> dict[str, Any]:
        operation_id = hashlib.sha256(f"{scope}:{target}:{action}".encode()).hexdigest()[:16]
        return {"operation_id": operation_id, "changed": True, "state": "accepted", "message": action}

    def list_admin(self, kind: str) -> list[dict[str, Any]]:
        return [redact(item) for item in self.admin[kind].values()]

    def upsert_admin(self, kind: str, resource: AdminResource) -> tuple[dict[str, Any], bool]:
        key = resource.id or f"{resource.implementation}:{resource.name.casefold()}"
        value = resource.model_copy(update={"id": key}).model_dump()
        changed = self.admin[kind].get(key) != value
        self.admin[kind][key] = value
        self._save_admin()
        result = {
            "operation_id": hashlib.sha256(f"{kind}:{key}".encode()).hexdigest()[:16],
            "changed": changed, "state": "accepted", "message": f"Đã lưu {resource.name}",
            "data": redact(value),
        }
        return result, changed

    def delete_admin(self, kind: str, item_id: str) -> bool:
        changed = self.admin[kind].pop(item_id, None) is not None
        if changed:
            self._save_admin()
        return changed

    def _save_admin(self) -> None:
        if not self.state_path:
            return
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        document = {**self.admin, "requests": self.requests}
        self.state_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
        os.chmod(self.state_path, 0o600)
