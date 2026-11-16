import asyncio

import httpx
import pytest

from app.cache import MemoryCache
from app.config import Settings
from app.links.adapters.apple import AppleMusicAdapter
from app.links.adapters.odesli import OdesliAdapter
from app.links.adapters.open_sources import CreativeCommonsSearchAdapter, InternetArchiveAdapter, JamendoAdapter
from app.links.adapters.soundcloud import SoundCloudAdapter
from app.links.adapters.spotify import SpotifyAdapter
from app.links.adapters.vn import ZingMp3Adapter
from app.links.adapters.web_search import WebSearchAdapter
from app.links.adapters.youtube import YouTubeAdapter, iso_duration_ms
from app.links.base import Adapter, ResolveContext, TrackInfo
from app.links.circuit import BreakerRegistry, CircuitBreaker
from app.links.resolver import LinkResolver
from app.platforms import search_url


def make_ctx(http, *, settings=None, variant=None, **track) -> ResolveContext:
    info = TrackInfo(id="trk_1", title=track.pop("title", "Nơi Này Có Anh"),
                     artists=track.pop("artists", ["Sơn Tùng M-TP"]), duration_ms=track.pop("duration_ms", 260000),
                     **track)
    return ResolveContext(track=info, country="VN", variant=variant, http=http, cache=MemoryCache(),
                          settings=settings or Settings(_env_file=None))


@pytest.fixture
async def http():
    async with httpx.AsyncClient() as client:
        yield client


def test_search_urls_encode_vietnamese():
    assert search_url("zing_mp3", "Nơi Này Có Anh Sơn Tùng") == \
        "https://zingmp3.vn/tim-kiem/bai-hat?q=N%C6%A1i+N%C3%A0y+C%C3%B3+Anh+S%C6%A1n+T%C3%B9ng"
    assert search_url("spotify", "a b") == "https://open.spotify.com/search/a%20b"
    assert search_url("apple_music", "x", "VN") == "https://music.apple.com/vn/search?term=x"
    assert search_url("nct", "x", overrides={"nct": "https://nct.example/s?k={q}"}) == "https://nct.example/s?k=x"


def test_iso_duration():
    assert iso_duration_ms("PT4M20S") == 260000
    assert iso_duration_ms("PT1H2S") == 3602000
    assert iso_duration_ms("") is None


async def test_youtube_search_scores_and_counts_quota(http, mock_http):
    settings = Settings(_env_file=None, youtube_api_key="k", youtube_search_daily_limit=1)
    ctx = make_ctx(http, settings=settings)
    mock_http.get("https://www.googleapis.com/youtube/v3/search").respond(json={"items": [
        {"id": {"videoId": "mv"}, "snippet": {"title": "SƠN TÙNG M-TP | NƠI NÀY CÓ ANH | OFFICIAL MUSIC VIDEO",
                                              "channelTitle": "Sơn Tùng M-TP Official"}},
        {"id": {"videoId": "audio"}, "snippet": {"title": "Nơi Này Có Anh", "channelTitle": "Sơn Tùng M-TP - Topic"}},
        {"id": {"videoId": "cover"}, "snippet": {"title": "Nơi Này Có Anh - cover", "channelTitle": "Ai đó"}},
    ]})
    mock_http.get("https://www.googleapis.com/youtube/v3/videos").respond(json={"items": [
        {"id": "mv", "contentDetails": {"duration": "PT5M10S"}},
        {"id": "audio", "contentDetails": {"duration": "PT4M21S"}},
        {"id": "cover", "contentDetails": {"duration": "PT4M20S"}},
    ]})
    adapter = YouTubeAdapter()
    [link] = await adapter.resolve(ctx)
    assert link.url == "https://www.youtube.com/watch?v=audio" and link.match == "exact"
    # Daily budget of search.list spent → QuotaExhausted, the resolver then uses the fallback.
    with pytest.raises(Exception, match="budget"):
        await adapter.resolve(ctx)
    [fallback] = adapter.fallback(ctx)
    assert fallback.match == "search" and fallback.url.startswith("https://www.youtube.com/results?search_query=")


async def test_spotify_isrc_then_name(http, mock_http):
    settings = Settings(_env_file=None, spotify_client_id="id", spotify_client_secret="secret")
    token = mock_http.post("https://accounts.spotify.com/api/token").respond(
        json={"access_token": "tok", "expires_in": 3600})
    search = mock_http.get("https://api.spotify.com/v1/search").respond(json={"tracks": {"items": [
        {"name": "Nơi Này Có Anh", "artists": [{"name": "Sơn Tùng M-TP"}], "duration_ms": 260500,
         "external_urls": {"spotify": "https://open.spotify.com/track/abc"}},
    ]}})
    ctx = make_ctx(http, settings=settings, isrc="VNA0Z1700001")
    links = await SpotifyAdapter().resolve(ctx)
    assert {(l.kind, l.url) for l in links} == {("listen", "https://open.spotify.com/track/abc"),
                                               ("offline_in_app", "https://open.spotify.com/track/abc")}
    assert search.calls.last.request.url.params["q"] == "isrc:VNA0Z1700001"
    assert search.calls.last.request.headers["authorization"] == "Bearer tok"
    await SpotifyAdapter().resolve(ctx)
    assert token.call_count == 1  # token cached


async def test_soundcloud_downloadable_and_purchase(http, mock_http):
    settings = Settings(_env_file=None, soundcloud_client_id="id", soundcloud_client_secret="s")
    mock_http.post("https://secure.soundcloud.com/oauth/token").respond(json={"access_token": "t", "expires_in": 3600})
    mock_http.get("https://api.soundcloud.com/tracks").respond(json={"collection": [
        {"title": "Lofi Rain", "user": {"username": "Chill Cat"}, "duration": 180000,
         "permalink_url": "https://soundcloud.com/chillcat/lofi-rain", "downloadable": True, "license": "cc-by",
         "purchase_url": "https://chillcat.bandcamp.com/track/lofi-rain"},
    ]})
    ctx = make_ctx(http, settings=settings, title="Lofi Rain", artists=["Chill Cat"], duration_ms=181000,
                   is_instrumental=True)
    links = await SoundCloudAdapter().resolve(ctx)
    assert {(l.kind, l.license) for l in links} == {("listen", None), ("free_download", "CC BY"), ("buy", None)}


async def test_apple_itunes_buy_link(http, mock_http):
    mock_http.get("https://itunes.apple.com/search").respond(json={"results": [
        {"trackName": "Nơi Này Có Anh", "artistName": "Sơn Tùng M-TP", "trackTimeMillis": 259000,
         "trackPrice": 0.99, "trackViewUrl": "https://music.apple.com/vn/album/x/1?i=2"},
    ]})
    links = await AppleMusicAdapter().resolve(make_ctx(http))
    assert [(l.platform, l.kind) for l in links] == [("apple_music", "listen"), ("itunes", "buy")]
    assert links[1].url.endswith("&app=itunes")


async def test_odesli_keeps_only_secondary_platforms(http, mock_http):
    mock_http.get("https://api.song.link/v1-alpha.1/links").respond(json={"linksByPlatform": {
        "spotify": {"url": "https://open.spotify.com/track/sp1"},
        "tidal": {"url": "https://listen.tidal.com/track/1"},
        "amazonStore": {"url": "https://amazon.com/dp/B1"},
    }})
    ctx = make_ctx(http, external_ids={"spotify": "sp1"})
    links = await OdesliAdapter().resolve(ctx)
    assert {(l.platform, l.kind) for l in links} == {("tidal", "listen"), ("amazon_store", "buy")}


async def test_odesli_rate_limit(http, mock_http):
    settings = Settings(_env_file=None, odesli_per_minute=0)
    assert await OdesliAdapter().resolve(make_ctx(http, settings=settings, external_ids={"spotify": "x"})) == []


async def test_jamendo_and_archive_licences(http, mock_http):
    settings = Settings(_env_file=None, jamendo_client_id="cid")
    mock_http.get("https://api.jamendo.com/v3.0/tracks/").respond(json={"results": [
        {"id": "1", "name": "Morning Light", "artist_name": "Piano Guy", "duration": 200,
         "shareurl": "https://www.jamendo.com/track/1", "license_ccurl": "http://creativecommons.org/licenses/by/3.0/"},
    ]})
    ctx = make_ctx(http, settings=settings, title="Morning Light", artists=["Piano Guy"], duration_ms=201000)
    links = await JamendoAdapter().resolve(ctx)
    assert {(l.kind, l.license) for l in links} == {("listen", "CC BY 3.0"), ("free_download", "CC BY 3.0")}

    mock_http.get("https://archive.org/advancedsearch.php").respond(json={"response": {"docs": [
        {"identifier": "gymnopedie", "title": "Gymnopédie No. 1", "creator": "Erik Satie",
         "licenseurl": "http://creativecommons.org/publicdomain/mark/1.0/"},
        {"identifier": "other", "title": "Gymnopédie No. 1", "creator": "Erik Satie", "licenseurl": ""},
    ]}})
    ctx = make_ctx(http, title="Gymnopédie No. 1", artists=["Erik Satie"], duration_ms=None)
    [link] = await InternetArchiveAdapter().resolve(ctx)
    assert link.url == "https://archive.org/details/gymnopedie" and link.license == "Public Domain"


def test_cc_search_only_for_instrumental(http):
    assert CreativeCommonsSearchAdapter().fallback(make_ctx(http)) == []
    ctx = make_ctx(http, title="Clair de Lune", artists=["Claude Debussy"], is_instrumental=True,
                   genres=["Classical"], work_title="Clair de Lune")
    platforms = {l.platform for l in CreativeCommonsSearchAdapter().fallback(ctx)}
    assert platforms == {"free_music_archive", "jamendo", "musopen"}


def test_vn_beat_variant(http):
    links = ZingMp3Adapter().fallback(make_ctx(http, variant="beat"))
    assert [l.kind for l in links] == ["listen", "offline_in_app", "listen"]
    assert "beat" in links[-1].url


async def test_web_search_whitelist(http, mock_http):
    settings = Settings(_env_file=None, brave_search_api_key="k")
    mock_http.get("https://api.search.brave.com/res/v1/web/search").respond(json={"web": {"results": [
        {"url": "https://artist.bandcamp.com/track/morning-light", "title": "Morning Light | Piano Guy"},
        {"url": "https://free-mp3-download.example/morning-light", "title": "Morning Light - Piano Guy mp3"},
    ]}})
    ctx = make_ctx(http, settings=settings, title="Morning Light", artists=["Piano Guy"])
    links = await WebSearchAdapter().resolve(ctx)
    assert [(l.platform, l.kind) for l in links] == [("bandcamp", "buy")]


def test_circuit_breaker_opens_and_half_opens(monkeypatch):
    now = [100.0]
    monkeypatch.setattr("app.links.circuit.time.monotonic", lambda: now[0])
    cb = CircuitBreaker(threshold=2, reset_s=30)
    cb.failure()
    assert cb.allow()
    cb.failure()
    assert not cb.allow()
    now[0] += 31
    assert cb.allow()  # half-open trial
    cb.failure()
    assert not cb.allow()
    now[0] += 31
    assert cb.allow()
    cb.success()
    assert cb.allow() and not cb.is_open


class SlowAdapter(Adapter):
    name = "slow"

    async def resolve(self, ctx):
        await asyncio.sleep(5)
        return []

    def fallback(self, ctx):
        return [ctx.search_link("youtube")]


async def test_resolver_timeout_uses_fallback_and_breaker(settings, http):
    from app.db import Database
    from app.models import Track

    db = Database(settings.database_url)
    await db.create_all()
    async with db.sessionmaker() as s:
        s.add(Track(id="trk_1", match_key="k", title="Song", artists=["A"]))
        await s.commit()
        track = await s.get(Track, "trk_1")
    settings = settings.model_copy(update={"adapter_timeout_s": 0.05, "circuit_failure_threshold": 1})
    breakers = BreakerRegistry(1, 60)
    resolver = LinkResolver(settings, http, MemoryCache(), db.sessionmaker, breakers, adapters=[SlowAdapter()])
    events = [e async for e in resolver.stream(track, "VN")]
    assert events[0].degraded and events[0].links[0]["match"] == "search"
    assert breakers.get("slow").is_open
    await db.dispose()
