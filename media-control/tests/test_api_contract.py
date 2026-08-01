from fastapi.testclient import TestClient

from media_control.app import create_app
from media_control.hub import MemoryHub


TOKEN = "local-control-token"


def client() -> TestClient:
    return TestClient(create_app(token=TOKEN, hub=MemoryHub()))


def auth() -> dict[str, str]:
    return {"Authorization": f"Bearer {TOKEN}"}


def test_every_v1_route_requires_bearer_token() -> None:
    response = client().get("/v1/status")
    assert response.status_code == 401
    assert response.json() == {"detail": "Missing or invalid control token"}


def test_public_read_contracts_have_stable_shapes() -> None:
    api = client()
    for path, key in [
        ("/v1/status", "state"),
        ("/v1/services", "services"),
        ("/v1/storage", "mount"),
        ("/v1/library", "items"),
        ("/v1/downloads", "jobs"),
        ("/v1/subtitles", "items"),
    ]:
        response = api.get(path, headers=auth())
        assert response.status_code == 200
        assert key in response.json()


def test_search_then_repeated_request_is_idempotent() -> None:
    api = client()
    search = api.get(
        "/v1/discover/search", params={"q": "Arrival"}, headers=auth()
    )
    assert search.status_code == 200
    media = search.json()["items"][0]
    payload = {
        "media_type": media["media_type"],
        "external_id": media["external_id"],
        "title": media["title"],
        "quality": "1080p",
    }
    first = api.post("/v1/requests", json=payload, headers=auth())
    second = api.post("/v1/requests", json=payload, headers=auth())
    assert first.status_code == 201
    assert second.status_code == 200
    assert first.json()["operation_id"] == second.json()["operation_id"]
    assert second.json()["changed"] is False


def test_destructive_library_delete_requires_scoped_confirmation() -> None:
    api = client()
    first = api.delete("/v1/library/movie-1", headers=auth())
    assert first.status_code == 409
    confirmation = first.json()["detail"]["confirmation_token"]

    wrong_target = api.delete(
        "/v1/library/movie-2",
        headers={**auth(), "X-Confirmation-Token": confirmation},
    )
    assert wrong_target.status_code == 409

    confirmed = api.delete(
        "/v1/library/movie-1",
        headers={**auth(), "X-Confirmation-Token": confirmation},
    )
    assert confirmed.status_code == 200
    assert confirmed.json()["changed"] is True


def test_admin_crud_is_idempotent_and_redacts_secrets() -> None:
    api = client()
    payload = {
        "name": "OpenSubtitles",
        "implementation": "opensubtitlescom",
        "enabled": True,
        "settings": {"username": "demo", "password": "very-secret"},
    }
    created = api.post("/v1/admin/providers", json=payload, headers=auth())
    repeated = api.post("/v1/admin/providers", json=payload, headers=auth())
    assert created.status_code == 201
    assert repeated.status_code == 200
    body = repeated.json()
    assert body["changed"] is False
    assert "very-secret" not in str(body)
    listing = api.get("/v1/admin/providers", headers=auth()).json()
    assert listing["items"][0]["settings"]["password"] == "***"


def test_sse_endpoint_emits_snapshot_without_secret() -> None:
    api = client()
    with api.stream("GET", "/v1/events", headers=auth()) as response:
        chunk = next(response.iter_text())
    assert response.status_code == 200
    assert "event: snapshot" in chunk
    assert TOKEN not in chunk
