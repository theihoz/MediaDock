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


def test_seerr_4k_request_overrides_profile_without_fake_4k_server() -> None:
    seen = {}

    def request(request: httpx.Request) -> httpx.Response:
        seen.update(__import__("json").loads(request.content))
        return httpx.Response(201, json={"id": 1}, request=request)

    adapter = SeerrAdapter(api_key="key", transport=httpx.MockTransport(request))
    adapter.create_request("movie", "tmdb:123", "4k")
    assert seen["profileId"] == 5
    assert seen["rootFolder"] == "/data/library/movies"
    assert seen["is4k"] is False


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


def test_servarr_delete_media_uses_delete_files_guard() -> None:
    seen: list[httpx.Request] = []

    def delete(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={}, request=request)

    adapter = RadarrAdapter(api_key="key", transport=httpx.MockTransport(delete))
    adapter.delete_media("movie", 42)
    assert seen[0].url.path == "/api/v3/movie/42"
    assert seen[0].url.params["deleteFiles"] == "true"


def test_bazarr_normalizes_wanted_items_and_searches_vietnamese() -> None:
    paths: list[tuple[str, str]] = []

    def bazarr(request: httpx.Request) -> httpx.Response:
        paths.append((request.method, request.url.path))
        if request.url.path.endswith("/movies/wanted"):
            return httpx.Response(200, json={"data": [{
                "radarrId": 7, "title": "Arrival", "missing_subtitles": ["vi", "en"],
            }]}, request=request)
        return httpx.Response(200, json={"data": []}, request=request)

    adapter = BazarrAdapter(api_key="key", transport=httpx.MockTransport(bazarr))
    items = adapter.subtitle_items()
    assert items[0]["id"] == "movie:7"
    assert items[0]["vietnamese"] is False
    adapter.subtitle_action("movie:7", "search")
    assert ("PATCH", "/api/movies/subtitles") in paths
