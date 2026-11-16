import base64
import hashlib
import hmac

import httpx
import pytest

from app.config import Settings
from app.recognition.acrcloud import ACRCloudClient, ACRCloudEngine
from app.recognition.audd import AudDEngine
from app.recognition.base import EngineError, EngineMatch, EngineQuotaError, TrackMeta
from app.recognition.cascade import EnginesUnavailable, RecognitionCascade, candidate_flags

ACR_MATCH = {
    "status": {"msg": "Success", "code": 0, "version": "1.0"},
    "metadata": {
        "music": [
            {
                "title": "Nơi Này Có Anh",
                "artists": [{"name": "Sơn Tùng M-TP"}],
                "album": {"name": "Nơi Này Có Anh"},
                "duration_ms": 260000,
                "score": 100,
                "acrid": "abc123",
                "genres": [{"name": "Pop"}],
                "external_ids": {"isrc": "VNA0Z1700001", "upc": "123"},
                "external_metadata": {
                    "spotify": {"track": {"id": "sp123"}},
                    "deezer": {"track": {"id": 555}},
                    "youtube": {"vid": "yt123"},
                },
            },
            {
                "title": "Nơi Này Có Anh (Instrumental)",
                "artists": [{"name": "Sơn Tùng M-TP"}],
                "score": 80,
            },
        ]
    },
}


@pytest.fixture
async def http():
    async with httpx.AsyncClient() as client:
        yield client


async def test_acrcloud_signs_and_parses(http, mock_http):
    route = mock_http.post("https://identify-ap-southeast-1.acrcloud.com/v1/identify").respond(json=ACR_MATCH)
    client = ACRCloudClient(http, "identify-ap-southeast-1.acrcloud.com", "key", "secret")
    matches = await ACRCloudEngine(client, None).fingerprint(b"audio", "sample.aac")

    assert route.called
    body = route.calls.last.request.content
    assert b'name="access_key"' in body and b"key" in body and b'name="sample"' in body
    expected = base64.b64encode(hmac.new(b"secret", b"POST\n/v1/identify\nkey\naudio\n1\n123", hashlib.sha1).digest())
    assert client.sign("123").encode() == expected

    top = matches[0]
    assert top.confidence == 1.0 and top.engine == "acrcloud"
    assert top.track.isrc == "VNA0Z1700001"
    assert top.track.external_ids == {"spotify": "sp123", "deezer": "555", "youtube": "yt123", "acrid": "abc123"}
    assert top.track.genres == ["Pop"]


async def test_acrcloud_no_result_and_errors(http, mock_http):
    url = "https://h.acrcloud.com/v1/identify"
    client = ACRCloudClient(http, "h.acrcloud.com", "k", "s")
    mock_http.post(url).respond(json={"status": {"code": 1001, "msg": "No result"}})
    assert await ACRCloudEngine(client, None).fingerprint(b"a", "s.aac") == []
    mock_http.post(url).respond(json={"status": {"code": 3003, "msg": "limit exceeded"}})
    with pytest.raises(EngineQuotaError):
        await client.identify(b"a", "s.aac")
    mock_http.post(url).respond(500)
    with pytest.raises(EngineError):
        await client.identify(b"a", "s.aac")


async def test_acrcloud_cover_reads_humming_results(http, mock_http):
    mock_http.post("https://h.acrcloud.com/v1/identify").respond(json={
        "status": {"code": 0},
        "metadata": {"humming": [{"title": "Song A", "artists": [{"name": "X"}], "score": 0.72},
                                 {"title": "Song B", "artists": [{"name": "Y"}], "score": 0.41}]},
    })
    client = ACRCloudClient(http, "h.acrcloud.com", "k", "s")
    matches = await ACRCloudEngine(client, client).cover(b"a", "s.aac")
    assert [m.track.title for m in matches] == ["Song A", "Song B"]
    assert matches[0].confidence == 0.72 and matches[0].via == "cover"


async def test_audd_parses_links(http, mock_http):
    mock_http.post("https://api.audd.io/").respond(json={
        "status": "success",
        "result": {
            "artist": "Imagine Dragons, JID", "title": "Enemy", "album": "Arcane", "song_link": "https://lis.tn/x",
            "apple_music": {"url": "https://music.apple.com/us/album/x?i=1", "isrc": "USUM72118351",
                            "artwork": {"url": "https://img/{w}x{h}bb.jpg"}, "genreNames": ["Alternative"]},
            "spotify": {"id": "sp1", "duration_ms": 173000},
            "deezer": {"id": 42},
        },
    })
    [m] = await AudDEngine(http, "token").identify(b"a", "s.aac")
    assert m.track.artists == ["Imagine Dragons", "JID"]
    assert m.track.isrc == "USUM72118351"
    assert m.track.artwork_url == "https://img/600x600bb.jpg"
    assert m.track.external_ids["apple_music_url"].startswith("https://music.apple.com")
    assert m.track.duration_ms == 173000


async def test_audd_no_match_and_quota(http, mock_http):
    mock_http.post("https://api.audd.io/").respond(json={"status": "success", "result": None})
    assert await AudDEngine(http, "t").identify(b"a", "s.aac") == []
    mock_http.post("https://api.audd.io/").respond(json={"status": "error", "error": {"error_code": 901}})
    with pytest.raises(EngineQuotaError):
        await AudDEngine(http, "t").identify(b"a", "s.aac")


def m(title: str, conf: float, via: str = "fingerprint", engine: str = "acrcloud") -> EngineMatch:
    return EngineMatch(TrackMeta(title=title, artists=["Artist"]), conf, engine, via)


class FakeACR:
    name = "acrcloud"

    def __init__(self, fingerprint=None, cover=None, fail=False):
        self._fp, self._cover, self.fail = fingerprint or [], cover or [], fail
        self.calls: list[str] = []

    async def fingerprint(self, audio, filename):
        self.calls.append("fingerprint")
        if self.fail:
            raise EngineError("down")
        return self._fp

    async def cover(self, audio, filename):
        self.calls.append("cover")
        if self.fail:
            raise EngineError("down")
        return self._cover


class FakeAudD:
    name = "audd"

    def __init__(self, result=None, fail=False):
        self.result, self.fail, self.calls = result or [], fail, 0

    async def identify(self, audio, filename):
        self.calls += 1
        if self.fail:
            raise EngineError("down")
        return self.result


def cascade(acr=None, audd=None, **kw) -> RecognitionCascade:
    settings = Settings(_env_file=None, acrcloud_host="h", acrcloud_access_key="k", acrcloud_access_secret="s", **kw)
    return RecognitionCascade(settings, acr, audd)


async def test_early_probe_needs_high_score():
    acr = FakeACR([m("Song", 0.95)])
    out = await cascade(acr).run(b"x", "s.aac", mode="auto", stage="early")
    assert out.status == "matched" and out.final

    acr = FakeACR([m("Song", 0.75)])
    out = await cascade(acr, FakeAudD([m("Other", 0.9, engine="audd")])).run(b"x", "s.aac", mode="auto", stage="early")
    assert out.status == "no_match" and out.final is False
    assert acr.calls == ["fingerprint"]  # no AudD, no cover on the 6 s probe


async def test_full_cascade_order():
    acr = FakeACR([m("Weak", 0.5)], cover=[m("C1", 0.8, "cover"), m("C2", 0.6, "cover"),
                                          m("C3", 0.5, "cover"), m("C4", 0.4, "cover")])
    audd = FakeAudD([])
    out = await cascade(acr, audd).run(b"x", "s.aac", mode="auto", stage="full")
    assert acr.calls == ["fingerprint", "cover"] and audd.calls == 1
    assert out.status == "candidates" and out.engine == "acrcloud_cover"
    assert [c.track.title for c in out.matches] == ["C1", "C2", "C3"]  # at most 3

    audd = FakeAudD([m("From AudD", 0.9, engine="audd")])
    out = await cascade(FakeACR([]), audd).run(b"x", "s.aac", mode="auto", stage="full")
    assert out.status == "matched" and out.engine == "audd"


async def test_hum_mode_goes_straight_to_cover():
    acr = FakeACR([m("Song", 1.0)], cover=[m("Hummed", 0.7, "cover")])
    out = await cascade(acr).run(b"x", "s.aac", mode="hum", stage="full")
    assert acr.calls == ["cover"] and out.status == "candidates"
    assert candidate_flags(out, mode="hum", filename_hint=None) == [["melody"]]


async def test_no_match_and_all_engines_down():
    out = await cascade(FakeACR([], cover=[]), FakeAudD([])).run(b"x", "s.aac", mode="auto", stage="full")
    assert out.status == "no_match" and out.final
    with pytest.raises(EnginesUnavailable):
        await cascade(FakeACR(fail=True), FakeAudD(fail=True)).run(b"x", "s.aac", mode="auto", stage="full")
    # One engine down, the other answers "no match" → a normal no_match.
    out = await cascade(FakeACR(fail=True), FakeAudD([])).run(b"x", "s.aac", mode="auto", stage="full")
    assert out.status == "no_match" and out.errors


async def test_maybe_beat_flag():
    acr = FakeACR([m("Shape of You", 0.9), m("Shape of You (Instrumental)", 0.85)])
    out = await cascade(acr).run(b"x", "s.aac", mode="auto", stage="full")
    assert candidate_flags(out, mode="auto", filename_hint=None) == [["maybe_beat"]]

    acr = FakeACR([m("Shape of You", 0.9)])
    out = await cascade(acr).run(b"x", "s.aac", mode="auto", stage="full")
    assert candidate_flags(out, mode="auto", filename_hint=None) == [[]]
    assert candidate_flags(out, mode="auto", filename_hint="shape_of_you_karaoke.mp3") == [["maybe_beat"]]


async def test_cover_step_flags_cover():
    acr = FakeACR([], cover=[m("Original Song", 0.8, "cover")])
    out = await cascade(acr).run(b"x", "s.aac", mode="auto", stage="full")
    assert candidate_flags(out, mode="auto", filename_hint=None) == [["cover"]]
