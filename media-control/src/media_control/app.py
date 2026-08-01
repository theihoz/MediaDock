from __future__ import annotations

import json
import os
from collections.abc import Callable
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, status
from fastapi.responses import StreamingResponse

from .hub import MemoryHub
from .models import AdminResource, MediaRequest
from .security import ConfirmationStore, redact


def create_app(token: str | None = None, hub: Any | None = None) -> FastAPI:
    control_token = token or os.environ.get("MEDIA_CONTROL_TOKEN", "")
    if not control_token:
        raise RuntimeError("MEDIA_CONTROL_TOKEN is required")
    if hub is not None:
        services = hub
    elif os.environ.get("MEDIA_CONTROL_LIVE") == "1":
        from .live import LiveHub
        services = LiveHub()
    else:
        services = MemoryHub()
    confirmations = ConfirmationStore()
    app = FastAPI(title="Server Phim media-control", version="1.0.0", docs_url=None, redoc_url=None)

    def authorize(authorization: Annotated[str | None, Header()] = None) -> None:
        if authorization != f"Bearer {control_token}":
            raise HTTPException(status_code=401, detail="Missing or invalid control token")

    auth = Depends(authorize)

    @app.exception_handler(Exception)
    async def safe_error(_request: Request, exception: Exception):
        from fastapi.responses import JSONResponse
        if isinstance(exception, HTTPException):
            return JSONResponse(status_code=exception.status_code, content={"detail": redact(exception.detail)})
        return JSONResponse(status_code=500, content={"detail": "Internal service error"})

    @app.get("/v1/status", dependencies=[auth])
    def get_status():
        return services.status()

    @app.get("/v1/services", dependencies=[auth])
    def get_services():
        return {"services": services.services()}

    @app.get("/v1/storage", dependencies=[auth])
    def get_storage():
        return services.storage()

    @app.get("/v1/events", dependencies=[auth])
    def events():
        snapshot = redact({"status": services.status(), "services": services.services()})

        def stream():
            yield f"event: snapshot\ndata: {json.dumps(snapshot)}\n\n"

        return StreamingResponse(stream(), media_type="text/event-stream")

    @app.get("/v1/discover/search", dependencies=[auth])
    def search(q: Annotated[str, Query(min_length=1)]):
        return {"items": services.search(q)}

    @app.post("/v1/requests", dependencies=[auth])
    def request_media(payload: MediaRequest):
        result, changed = services.request(payload)
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=201 if changed else 200, content=redact(result))

    @app.get("/v1/library", dependencies=[auth])
    def library():
        return {"items": services.library()}

    @app.delete("/v1/library/{item_id}", dependencies=[auth])
    def delete_library(item_id: str, confirmation: Annotated[str | None, Header(alias="X-Confirmation-Token")] = None):
        if not confirmations.consume(confirmation, "library", item_id):
            token_value = confirmations.issue("library", item_id)
            raise HTTPException(status_code=409, detail={
                "message": "Xác nhận xóa dữ liệu thư viện",
                "confirmation_token": token_value,
                "target": item_id,
            })
        changed = services.delete_library(item_id)
        return services.operation("library", item_id, "delete") | {"changed": changed}

    @app.get("/v1/downloads", dependencies=[auth])
    def downloads():
        return {"jobs": services.downloads()}

    def download_action(job_id: str, action: str):
        return services.operation("download", job_id, action)

    for action in ("pause", "resume", "retry"):
        app.add_api_route(
            f"/v1/downloads/{{job_id}}/{action}",
            lambda job_id, action=action: download_action(job_id, action),
            methods=["POST"], dependencies=[auth], name=f"download_{action}",
        )

    @app.post("/v1/downloads/{job_id}/cancel", dependencies=[auth])
    def cancel_download(job_id: str, confirmation: Annotated[str | None, Header(alias="X-Confirmation-Token")] = None):
        if not confirmations.consume(confirmation, "download", job_id):
            raise HTTPException(status_code=409, detail={
                "message": "Xác nhận hủy và xóa dữ liệu tải",
                "confirmation_token": confirmations.issue("download", job_id),
                "target": job_id,
            })
        return download_action(job_id, "cancel")

    @app.get("/v1/subtitles", dependencies=[auth])
    def subtitles():
        return {"items": services.subtitles(), "preferred": ["vi", "en"]}

    @app.post("/v1/subtitles/{item_id}/{action}", dependencies=[auth])
    def subtitle_action(item_id: str, action: str):
        if action not in {"search", "rescan"}:
            raise HTTPException(404, "Unknown subtitle operation")
        return services.operation("subtitle", item_id, action)

    for action in ("scan", "cleanup", "health-test", "update"):
        app.add_api_route(
            f"/v1/operations/{action}",
            lambda action=action: services.operation("stack", "all", action),
            methods=["POST"], dependencies=[auth], name=f"operation_{action.replace('-', '_')}",
        )

    def register_admin(kind: str) -> None:
        def list_items():
            return {"items": services.list_admin(kind)}

        def create_item(payload: AdminResource):
            result, changed = services.upsert_admin(kind, payload)
            from fastapi.responses import JSONResponse
            return JSONResponse(status_code=201 if changed else 200, content=redact(result))

        def update_item(item_id: str, payload: AdminResource):
            result, _changed = services.upsert_admin(kind, payload.model_copy(update={"id": item_id}))
            return redact(result)

        def delete_item(item_id: str):
            changed = services.delete_admin(kind, item_id)
            return services.operation(kind, item_id, "delete") | {"changed": changed}

        app.add_api_route(f"/v1/admin/{kind}", list_items, methods=["GET"], dependencies=[auth], name=f"list_{kind}")
        app.add_api_route(f"/v1/admin/{kind}", create_item, methods=["POST"], dependencies=[auth], name=f"create_{kind}")
        app.add_api_route(f"/v1/admin/{kind}/{{item_id}}", update_item, methods=["PUT"], dependencies=[auth], name=f"update_{kind}")
        app.add_api_route(f"/v1/admin/{kind}/{{item_id}}", delete_item, methods=["DELETE"], dependencies=[auth], name=f"delete_{kind}")

    for admin_kind in ("indexers", "clients", "profiles", "providers"):
        register_admin(admin_kind)

    return app


app = create_app(token=os.environ.get("MEDIA_CONTROL_TOKEN", "development-only"))
