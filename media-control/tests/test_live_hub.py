from media_control.live import LiveHub
from media_control.models import AdminResource


class Recorder:
    def __init__(self) -> None:
        self.calls = []

    def delete_media(self, resource, item_id):
        self.calls.append((resource, item_id))

    def subtitle_items(self):
        return [{"id": "movie:7", "title": "Arrival"}]

    def subtitle_action(self, target, action):
        self.calls.append((target, action))


def bare_hub() -> LiveHub:
    hub = LiveHub.__new__(LiveHub)
    hub.radarr = Recorder()
    hub.sonarr = Recorder()
    hub.lidarr = Recorder()
    hub.bazarr = Recorder()
    hub.requests = {}
    hub.admin = {kind: {} for kind in ("indexers", "clients", "profiles", "providers")}
    hub.state_path = None
    return hub


def test_live_library_delete_routes_to_matching_servarr() -> None:
    hub = bare_hub()
    assert hub.delete_library("movie-42") is True
    assert hub.radarr.calls == [("movie", 42)]
    assert hub.delete_library("invalid") is False


def test_live_subtitles_and_actions_route_to_bazarr() -> None:
    hub = bare_hub()
    assert hub.subtitles()[0]["id"] == "movie:7"
    hub.operation("subtitle", "movie:7", "search")
    assert hub.bazarr.calls == [("movie:7", "search")]


def test_schema_payload_rejects_unknown_fields_and_preserves_contract() -> None:
    schema = [{
        "implementation": "Torznab",
        "configContract": "TorznabSettings",
        "fields": [{"name": "baseUrl", "value": "old"}],
    }]
    resource = AdminResource(
        name="Tracker", implementation="Torznab", settings={"baseUrl": "https://example.test"}
    )
    payload = LiveHub._schema_payload(schema, resource)
    assert payload["configContract"] == "TorznabSettings"
    assert payload["fields"][0]["value"] == "https://example.test"

    invalid = resource.model_copy(update={"settings": {"password": "secret"}})
    try:
        LiveHub._schema_payload(schema, invalid)
    except ValueError as error:
        assert "password" in str(error)
    else:
        raise AssertionError("unknown schema field was accepted")


def test_update_payload_preserves_secret_fields_not_sent_by_app() -> None:
    existing = {
        "id": 9,
        "fields": [
            {"name": "host", "value": "old-host"},
            {"name": "password", "value": "existing-secret"},
        ],
    }
    payload, changed = LiveHub._update_payload(existing, {"host": "qbittorrent"})
    assert changed is True
    assert payload["fields"][0]["value"] == "qbittorrent"
    assert payload["fields"][1]["value"] == "existing-secret"
