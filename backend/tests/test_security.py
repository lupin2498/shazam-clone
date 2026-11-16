"""Bảo mật: khoá API không lọt vào log, link trả về app chỉ là http(s), token admin, tải lên quá cỡ."""

from __future__ import annotations

import logging

import httpx
import pytest

from tests.conftest import adts_stream, wav_bytes

YT_SEARCH = "https://www.googleapis.com/youtube/v3/search"
YT_KEY = "AIzaSyTEST-secret-youtube-key-0123456789"
JAMENDO = "https://api.jamendo.com/v3.0/tracks/"
JAMENDO_ID = "jamendo-client-id-9f8e7d6c"


async def track_id(client: httpx.AsyncClient) -> str:
    files = {"audio": ("sample.wav", wav_bytes(1.0), "audio/wav")}
    resp = await client.post("/v1/recognitions", files=files, data={"mode": "auto", "source": "mic"})
    assert resp.status_code == 200, resp.text
    return resp.json()["candidates"][0]["track"]["id"]


@pytest.mark.parametrize("status", [200, 400, 403, 500])
async def test_api_keys_never_reach_the_logs(make_client, settings, mock_http, caplog, status):
    """httpx ghi URL đầy đủ ở mức INFO và trong thông báo lỗi; URL của YouTube/Jamendo chứa khoá."""
    mock_http.get(YT_SEARCH).respond(status, json={"items": [], "error": {"message": "bad"}})
    mock_http.get(JAMENDO).respond(status, json={"results": []})
    client = await make_client(settings.model_copy(update={
        "enabled_adapters": "youtube,jamendo", "youtube_api_key": YT_KEY, "jamendo_client_id": JAMENDO_ID,
    }))
    tid = await track_id(client)
    with caplog.at_level(logging.DEBUG):
        resp = await client.get(f"/v1/tracks/{tid}/links", params={"stream": "false"})
    assert resp.status_code == 200
    assert mock_http.get(YT_SEARCH).called and mock_http.get(JAMENDO).called
    logged = "\n".join(r.getMessage() for r in caplog.records)
    assert YT_KEY not in logged
    assert JAMENDO_ID not in logged
    if status >= 400:
        # The failure itself is still reported, with the secret masked.
        assert "adapter youtube failed" in logged and "key=***" in logged


BAD_URLS = [
    "javascript:alert(document.cookie)",
    "intent://evil.example/#Intent;scheme=https;package=com.evil;end",
    "market://details?id=com.evil",
    "file:///data/data/vn.timnhac.app/databases/timnhac.db",
    "content://media/external/audio/1",
    "tel:+84900000000",
    "//evil.example/no-scheme",
    "https:///no-host",
    "https://evil.example/a b",
    "https://evil.example/\nSet-Cookie: x",
    "",
]


def test_safe_link_url_accepts_only_absolute_http_urls():
    from app.links.base import safe_link_url

    assert safe_link_url("https://open.spotify.com/track/abc") == "https://open.spotify.com/track/abc"
    assert safe_link_url("  HTTP://chillcat.bandcamp.com/track/lofi-rain ") == "HTTP://chillcat.bandcamp.com/track/lofi-rain"
    for url in [*BAD_URLS, None, 42, "https://evil.example/" + "a" * 3000]:
        assert safe_link_url(url) is None, url


async def test_uploader_controlled_purchase_url_cannot_inject_a_non_web_link(settings, mock_http):
    """SoundCloud ``purchase_url`` do người đăng bài tự đặt: app sẽ mở nó khi người dùng bấm "Mua và tải"."""
    from app.cache import MemoryCache
    from app.db import Database
    from app.links.adapters.soundcloud import SoundCloudAdapter
    from app.links.circuit import BreakerRegistry
    from app.links.resolver import LinkResolver
    from app.models import Track

    mock_http.post("https://secure.soundcloud.com/oauth/token").respond(json={"access_token": "t", "expires_in": 3600})
    settings = settings.model_copy(update={"soundcloud_client_id": "id", "soundcloud_client_secret": "s"})
    db = Database(settings.database_url)
    await db.create_all()
    async with db.sessionmaker() as s:
        s.add(Track(id="trk_1", match_key="k", title="Lofi Rain", artists=["Chill Cat"], duration_ms=181000))
        await s.commit()
        track = await s.get(Track, "trk_1")
    try:
        async with httpx.AsyncClient() as http:
            for i, bad in enumerate(BAD_URLS):
                mock_http.get("https://api.soundcloud.com/tracks").respond(json={"collection": [
                    {"title": "Lofi Rain", "user": {"username": "Chill Cat"}, "duration": 180000,
                     "permalink_url": "https://soundcloud.com/chillcat/lofi-rain", "purchase_url": bad},
                ]})
                resolver = LinkResolver(settings, http, MemoryCache(), db.sessionmaker, BreakerRegistry(5, 60),
                                        adapters=[SoundCloudAdapter()])
                links = await resolver.resolve_all(track, f"A{chr(65 + i)}")
                assert [(l["kind"], l["url"]) for l in links] == \
                    [("listen", "https://soundcloud.com/chillcat/lofi-rain")], bad
    finally:
        await db.dispose()


async def test_engine_ids_are_not_pasted_into_urls_unchecked(make_client, settings):
    """ID do engine trả về được ghép vào URL: giá trị lạ phải bị bỏ, lùi về link tìm kiếm."""
    from app.recognition.base import EngineMatch, TrackMeta
    from app.recognition.cascade import CascadeOutcome

    def customize(services):
        async def run(audio, filename, *, mode, stage):
            meta = TrackMeta(title="Bài Thử", artists=["Ca Sĩ"], duration_ms=200000, artwork_url="https://img.test/a.jpg",
                             external_ids={"youtube": "x&list=PL1#\"onclick", "spotify": "../../user/evil?x=1",
                                           "deezer": "12/../../x", "apple_music_url": "javascript:alert(1)"})
            return CascadeOutcome(status="matched", engine="acrcloud", matches=[EngineMatch(meta, 1.0, "acrcloud")])
        services.cascade.run = run

    client = await make_client(settings.model_copy(update={
        "enabled_adapters": "youtube,youtube_music,spotify,deezer,apple_music"}), customize)
    resp = await client.post("/v1/recognitions", files={"audio": ("s.aac", adts_stream(6), "audio/aac")})
    tid = resp.json()["candidates"][0]["track"]["id"]
    body = (await client.get(f"/v1/tracks/{tid}/links", params={"stream": "false"})).json()
    assert body["links"], "search links are still offered"
    for link in body["links"]:
        assert link["match"] == "search", link
        assert link["url"].startswith("https://"), link
        assert "evil" not in link["url"] and "onclick" not in link["url"] and "javascript" not in link["url"], link


def test_redact_masks_only_secret_parameters():
    from app.logsafe import RedactSecretsFilter, redact

    url = "GET https://x.test/a?part=snippet&q=monkey+key&key=AIza123&client_id=abc#frag"
    assert redact(url) == "GET https://x.test/a?part=snippet&q=monkey+key&key=***&client_id=***#frag"
    assert redact("nothing to hide: keyboard=1 monkey=2") == "nothing to hide: keyboard=1 monkey=2"

    record = logging.LogRecord("httpx", logging.INFO, __file__, 1, "HTTP Request: %s %s", ("GET", url), None)
    assert RedactSecretsFilter().filter(record) is True
    assert "AIza123" not in record.getMessage() and "key=***" in record.getMessage()
