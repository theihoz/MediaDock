from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class MediaItem(BaseModel):
    id: str
    external_id: str | None = None
    media_type: Literal["movie", "tv", "music"]
    title: str
    year: int | None = None
    status: str = "unknown"
    monitored: bool = True
    poster_url: str | None = None


class MediaRequest(BaseModel):
    media_type: Literal["movie", "tv", "music"]
    external_id: str
    title: str
    quality: Literal["1080p", "4k"] = "1080p"


class DownloadJob(BaseModel):
    id: str
    client: Literal["qbittorrent", "sabnzbd"]
    title: str
    progress: float = Field(ge=0, le=1)
    state: str
    speed_bytes: int = 0
    eta_seconds: int | None = None


class SubtitleState(BaseModel):
    id: str
    media_id: str
    title: str
    vietnamese: bool = False
    english: bool = False
    state: str = "missing"


class ServiceHealth(BaseModel):
    name: str
    state: Literal["healthy", "degraded", "offline", "awaiting_credentials"]
    latency_ms: int | None = None
    message: str | None = None


class StorageStatus(BaseModel):
    mount: str = "/data"
    total_bytes: int
    free_bytes: int
    used_percent: float


class OperationResult(BaseModel):
    operation_id: str
    changed: bool
    state: str = "accepted"
    message: str = ""
    data: dict[str, Any] = Field(default_factory=dict)


class AdminResource(BaseModel):
    id: str | None = None
    name: str
    implementation: str
    enabled: bool = True
    settings: dict[str, Any] = Field(default_factory=dict)
