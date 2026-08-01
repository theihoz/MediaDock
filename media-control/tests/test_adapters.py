import httpx

from media_control.adapters import (
    AutobrrAdapter,
    BazarrAdapter,
    CleanuparrAdapter,
    FlareSolverrAdapter,
    JellyfinAdapter,
    LidarrAdapter,
    ProwlarrAdapter,
    QBittorrentAdapter,
    RadarrAdapter,
    SabnzbdAdapter,
    SeerrAdapter,
    SonarrAdapter,
    WizarrAdapter,
)


def test_every_approved_service_has_a_named_adapter() -> None:
    adapters = [
        JellyfinAdapter(), SeerrAdapter(), RadarrAdapter(), SonarrAdapter(),
        LidarrAdapter(), ProwlarrAdapter(), BazarrAdapter(), QBittorrentAdapter(),
        SabnzbdAdapter(), AutobrrAdapter(), FlareSolverrAdapter(),
        CleanuparrAdapter(), WizarrAdapter(),
    ]
    assert [adapter.name for adapter in adapters] == [
        "jellyfin", "seerr", "radarr", "sonarr", "lidarr", "prowlarr",
        "bazarr", "qbittorrent", "sabnzbd", "autobrr", "flaresolverr",
        "cleanuparr", "wizarr",
    ]


def test_lidarr_uses_v1_while_other_servarr_adapters_use_v3() -> None:
    assert LidarrAdapter().api_prefix == "/api/v1"
    assert RadarrAdapter().api_prefix == "/api/v3"
    assert SonarrAdapter().api_prefix == "/api/v3"
    assert ProwlarrAdapter().api_prefix == "/api/v1"


def test_adapter_error_redacts_credentials_and_response_body() -> None:
    def fail(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text='{"apiKey":"server-secret"}', request=request)

    adapter = RadarrAdapter(api_key="server-secret", transport=httpx.MockTransport(fail))
    result = adapter.health()
    assert result["state"] == "degraded"
    assert "server-secret" not in str(result)


def test_seerr_search_normalizes_movie_and_tv_results() -> None:
    def search(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/search"
        return httpx.Response(200, json={"results": [
            {"id": 123, "mediaType": "movie", "title": "Arrival", "releaseDate": "2016-11-11"},
            {"id": 456, "mediaType": "tv", "name": "Dark", "firstAirDate": "2017-12-01"},
        ]}, request=request)

    adapter = SeerrAdapter(api_key="key", transport=httpx.MockTransport(search))
    items = adapter.search("arrival")
    assert items[0]["external_id"] == "tmdb:123"
    assert items[0]["year"] == 2016
    assert items[1]["media_type"] == "tv"
    assert items[1]["title"] == "Dark"


def test_qbittorrent_logs_in_before_reading_jobs() -> None:
    paths: list[str] = []

    def qbit(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        if request.url.path.endswith("/auth/login"):
            return httpx.Response(204, request=request)
        return httpx.Response(200, json=[], request=request)

    adapter = QBittorrentAdapter(password="not-printed", transport=httpx.MockTransport(qbit))
    assert adapter.jobs() == []
    assert paths == ["/api/v2/auth/login", "/api/v2/torrents/info"]
