from media_control.security import ConfirmationStore, redact
from media_control.hub import MemoryHub
from media_control.models import AdminResource


def test_redact_recurses_through_errors_and_settings() -> None:
    value = {
        "apiKey": "abc",
        "nested": [{"password": "def", "safe": "visible"}],
        "cookie": "ghi",
    }
    assert redact(value) == {
        "apiKey": "***",
        "nested": [{"password": "***", "safe": "visible"}],
        "cookie": "***",
    }


def test_confirmation_token_is_one_time_and_target_scoped() -> None:
    store = ConfirmationStore(ttl_seconds=30)
    token = store.issue("library", "movie-1")
    assert not store.consume(token, "library", "movie-2")
    assert store.consume(token, "library", "movie-1")
    assert not store.consume(token, "library", "movie-1")


def test_admin_secrets_persist_only_in_backend_state_file(tmp_path) -> None:
    state_file = tmp_path / "admin.json"
    hub = MemoryHub(state_path=state_file)
    hub.upsert_admin("providers", AdminResource(
        name="OpenSubtitles", implementation="OpenSubtitlesCom",
        settings={"username": "demo", "password": "secret"},
    ))
    restored = MemoryHub(state_path=state_file)
    listing = restored.list_admin("providers")
    assert listing[0]["settings"]["password"] == "***"
    assert "secret" in state_file.read_text()
