"""Engine trả lời sai dạng không được làm sập yêu cầu; tên nghệ sĩ và thang điểm được đọc đúng."""

from __future__ import annotations

import httpx
import pytest

from app.config import Settings
from app.recognition.acrcloud import ACRCloudClient, ACRCloudEngine
from app.recognition.audd import AudDEngine
from app.recognition.base import EngineError, split_artists
from app.recognition.cascade import RecognitionCascade

ACR_URL = "https://h.acrcloud.com/v1/identify"
AUDD_URL = "https://api.audd.io/"


@pytest.fixture
async def http():
    async with httpx.AsyncClient() as client:
        yield client


# --- engines answering with something unexpected ------------------------------------

@pytest.mark.parametrize("body", [
    ["not", "an", "object"],
    {"status": "ok"},
    {"status": {"code": 0}, "metadata": ["music"]},
    {"status": {"code": 0}, "metadata": {"music": [{"title": "x", "artists": ["plain string"], "score": 90}]}},
    {"status": {"code": 0}, "metadata": {"music": [{"title": "x", "artists": [{"name": "A"}], "score": "high"}]}},
    {"status": {"code": 0}, "metadata": {"music": [{"title": "x", "external_metadata": {"spotify": "sp1"}}]}},
    {"status": {"code": 0}, "metadata": {"music": "oops"}},
])
async def test_acrcloud_malformed_answers_are_engine_errors(http, mock_http, body):
    mock_http.post(ACR_URL).respond(json=body)
    client = ACRCloudClient(http, "h.acrcloud.com", "k", "s")
    engine = ACRCloudEngine(client, client)
    with pytest.raises(EngineError):
        await engine.fingerprint(b"a", "s.aac")
    # Same malformed items, where the Cover Song project puts them.
    if isinstance(body, dict) and isinstance(body.get("metadata"), dict) and "music" in body["metadata"]:
        mock_http.post(ACR_URL).respond(json={**body, "metadata": {"humming": body["metadata"]["music"]}})
    with pytest.raises(EngineError):
        await engine.cover(b"a", "s.aac")


@pytest.mark.parametrize("body", [
    ["not", "an", "object"],
    {"status": "success", "result": "a string"},
    {"status": "error", "error": "plain text"},
])
async def test_audd_malformed_answers_are_engine_errors(http, mock_http, body):
    mock_http.post(AUDD_URL).respond(json=body)
    with pytest.raises(EngineError):
        await AudDEngine(http, "token").identify(b"a", "s.aac")


async def test_audd_match_survives_malformed_optional_fields(http, mock_http):
    """Tên bài đã có thì ảnh bìa, thời lượng, ID hỏng không được làm mất kết quả (trước đây: KeyError → 500)."""
    mock_http.post(AUDD_URL).respond(json={"status": "success", "result": {
        "title": "Enemy", "artist": "Imagine Dragons, JID", "album": ["not", "text"],
        "spotify": {"album": {"images": [{}]}, "artists": "nope", "duration_ms": "long", "external_ids": []},
        "deezer": {"duration": "long", "album": "text"},
        "apple_music": "text",
    }})
    [m] = await AudDEngine(http, "token").identify(b"a", "s.aac")
    assert (m.track.title, m.track.artists) == ("Enemy", ["Imagine Dragons", "JID"])
    assert m.track.artwork_url is None and m.track.duration_ms is None and m.track.album is None
    assert m.track.external_ids == {}


async def test_malformed_acrcloud_answer_falls_through_to_audd(http, mock_http):
    mock_http.post(ACR_URL).respond(json=["unexpected"])
    mock_http.post(AUDD_URL).respond(json={"status": "success", "result": {"artist": "Queen", "title": "Bohemian Rhapsody"}})
    settings = Settings(_env_file=None, acrcloud_host="h.acrcloud.com", acrcloud_access_key="k",
                        acrcloud_access_secret="s", audd_api_token="t")
    acr = ACRCloudClient(http, "h.acrcloud.com", "k", "s")
    outcome = await RecognitionCascade(settings, ACRCloudEngine(acr, acr), AudDEngine(http, "t")).run(
        b"a", "s.aac", mode="auto", stage="full")
    assert outcome.status == "matched" and outcome.engine == "audd"
    assert outcome.matches[0].track.title == "Bohemian Rhapsody"


async def test_acrcloud_fingerprint_score_is_always_out_of_100(http, mock_http):
    """Điểm 1/100 từng bị đọc thành độ tin cậy 100% vì dùng chung phép đoán thang điểm của humming."""
    mock_http.post(ACR_URL).respond(json={"status": {"code": 0}, "metadata": {"music": [
        {"title": "Weak", "artists": [{"name": "A"}], "score": 1},
        {"title": "Strong", "artists": [{"name": "B"}], "score": 92},
    ]}})
    client = ACRCloudClient(http, "h.acrcloud.com", "k", "s")
    matches = await ACRCloudEngine(client, None).fingerprint(b"a", "s.aac")
    assert [(m.track.title, m.confidence) for m in matches] == [("Strong", 0.92), ("Weak", 0.01)]


# --- artist names ---------------------------------------------------------------------

@pytest.mark.parametrize("raw,expected", [
    ("Tyler, The Creator", ["Tyler, The Creator"]),
    ("Tyler, The Creator feat. Kali Uchis", ["Tyler, The Creator", "Kali Uchis"]),
    ("A$AP Rocky, Tyler, The Creator & Frank Ocean", ["A$AP Rocky", "Tyler, The Creator", "Frank Ocean"]),
    ("Earth, Wind & Fire", ["Earth, Wind & Fire"]),
    ("Simon & Garfunkel", ["Simon & Garfunkel"]),
    ("Crosby, Stills, Nash & Young", ["Crosby, Stills, Nash & Young"]),
    ("Imagine Dragons, JID", ["Imagine Dragons", "JID"]),
    ("Metro Boomin, The Weeknd & 21 Savage", ["Metro Boomin", "The Weeknd", "21 Savage"]),
    ("Sơn Tùng M-TP ft. Snoop Dogg", ["Sơn Tùng M-TP", "Snoop Dogg"]),
    ("B Ray x Masew", ["B Ray", "Masew"]),
    ("", []),
    (None, []),
])
def test_split_artists_keeps_names_that_contain_a_separator(raw, expected):
    assert split_artists(raw) == expected


async def test_audd_prefers_structured_artists(http, mock_http):
    mock_http.post(AUDD_URL).respond(json={"status": "success", "result": {
        "artist": "Some, Unknown Band & Friends", "title": "Song",
        "spotify": {"id": "sp1", "artists": [{"name": "Some, Unknown Band"}, {"name": "Friends"}]},
    }})
    [m] = await AudDEngine(http, "t").identify(b"a", "s.aac")
    assert m.track.artists == ["Some, Unknown Band", "Friends"]
