from __future__ import annotations

import secrets
import threading
import time
from typing import Any


SECRET_MARKERS = ("password", "token", "apikey", "api_key", "cookie", "secret")


def redact(value: Any) -> Any:
    """Return a log/response-safe copy of a nested value."""
    if isinstance(value, dict):
        return {
            key: "***" if any(marker in key.lower() for marker in SECRET_MARKERS) else redact(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    if isinstance(value, tuple):
        return tuple(redact(item) for item in value)
    return value


class ConfirmationStore:
    def __init__(self, ttl_seconds: int = 120) -> None:
        self.ttl_seconds = ttl_seconds
        self._tokens: dict[str, tuple[str, str, float]] = {}
        self._lock = threading.Lock()

    def issue(self, resource: str, target: str) -> str:
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._tokens[token] = (resource, target, time.monotonic() + self.ttl_seconds)
        return token

    def consume(self, token: str | None, resource: str, target: str) -> bool:
        if not token:
            return False
        with self._lock:
            record = self._tokens.get(token)
            if not record:
                return False
            stored_resource, stored_target, expires_at = record
            if time.monotonic() > expires_at:
                self._tokens.pop(token, None)
                return False
            if (stored_resource, stored_target) != (resource, target):
                return False
            self._tokens.pop(token, None)
            return True
