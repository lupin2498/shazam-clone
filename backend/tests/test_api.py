import json

import httpx
import pytest

from app.config import Settings
from app.models import TrackLink
from app.security.integrity import IntegrityVerifier, request_hash, sha256_hex
from tests.conftest import adts_stream, wav_bytes

DEEZER_SEARCH = "https://api.deezer.com/search"


@pytest.fixture(autouse=True)
def deezer(mock_http):
    mock_http.get(DEEZER_SEARCH).respond(json={"data": []})
    return mock_http


async def recognize(client: httpx.AsyncClient, audio: bytes | None = None, **form) -> httpx.Response:
    files = {"audio": ("sample.aac", audio if audio is not None else adts_stream(12.0), "audio/aac")}
    return await client.post("/v1/recognitions", files=files, data={"mode": "auto", "source": "mic", **form})


def parse_sse(text: str) -> list[tuple[str, dict]]:
    events = []
    for block in text.strip().split("\n\n"):
        lines = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line)
        events.append((lines["event"], json.loads(lines["data"])))
    return events


async def test_recognition_demo_flow(client):
    resp = await recognize(client)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "matched" and body["engine"] == "demo" and body["final"] is True
    assert body["id"].startswith("rec_")
    cand = body["candidates"][0]
    assert cand["track"]["id"].startswith("trk_") and cand["confidence"] == 0.95
    assert resp.headers["X-Quota-Remaining"] == "29"


async def test_hum_mode_returns_candidates(client):
    resp = await recognize(client, mode="hum", source="hum")
    body = resp.json()
    assert body["status"] == "candidates" and len(body["candidates"]) == 3
    assert all(c["flags"] == ["melody"] for c in body["candidates"])


async def test_same_track_is_stored_once(client):
    a = (await recognize(client, wav_bytes(2.0))).json()
    b = (await recognize(client, wav_bytes(2.0))).json()
    assert a["candidates"][0]["track"]["id"] == b["candidates"][0]["track"]["id"]


async def test_invalid_requests(client):
    resp = await client.post("/v1/recognitions", files={"audio": ("x", b"garbage-garbage-garbage", "audio/aac")},
                             headers={"X-Device-Id": "device-test-0001"})
    assert resp.status_code == 422 and resp.json()["error"] == "invalid_sample"
    resp = await recognize(client, adts_stream(20.0))
    assert resp.status_code == 422
    resp = await client.post("/v1/recognitions", files={"audio": ("s.aac", adts_stream(5), "audio/aac")},
                             headers={"X-Device-Id": ""})
    assert resp.status_code == 400 and resp.json()["error"] == "missing_device_id"


async def test_min_app_version(make_client, settings):
    client = await make_client(settings.model_copy(update={"min_app_version": "2.0.0"}))
    resp = await client.post("/v1/recognitions", files={"audio": ("s.aac", adts_stream(5), "audio/aac")},
                             headers={"X-App-Version": "1.4.2"})
    assert resp.status_code == 426


async def test_quota_counts_taps_not_samples(make_client, settings):
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 2}))
    # One tap = early probe + full sample, same session id → one unit.
    assert (await recognize(client, adts_stream(6), stage="early", session_id="s1")).status_code == 200
    assert (await recognize(client, adts_stream(12), stage="full", session_id="s1")).status_code == 200
    assert (await recognize(client, session_id="s2")).headers["X-Quota-Remaining"] == "0"
    resp = await recognize(client, session_id="s3")
    assert resp.status_code == 429 and resp.json()["error"] == "quota_exceeded"
    # Another device has its own quota.
    resp = await client.post("/v1/recognitions", files={"audio": ("s.aac", adts_stream(5), "audio/aac")},
                             headers={"X-Device-Id": "another-device-01"})
    assert resp.status_code == 200


async def test_engines_not_configured(make_client, settings):
    client = await make_client(settings.model_copy(update={"demo_mode": False}))
    resp = await recognize(client)
    assert resp.status_code == 503 and resp.json()["error"] == "no_engine"


async def test_integrity_enforced(make_client, settings, monkeypatch):
    client = await make_client(settings.model_copy(update={"integrity_mode": "enforce"}))
    resp = await recognize(client)
    assert resp.status_code == 403 and resp.json()["detail"] == "missing_token"

    audio = adts_stream(12)
    expected = request_hash("device-test-0001", "sess-1", "full", sha256_hex(audio))

    async def fake_decode(self, token):
        import time
        return {
            "requestDetails": {"requestPackageName": "vn.timnhac.app", "requestHash": token,
                               "timestampMillis": str(int(time.time() * 1000))},
            "appIntegrity": {"appRecognitionVerdict": "PLAY_RECOGNIZED"},
            "deviceIntegrity": {"deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"]},
        }

    monkeypatch.setattr(IntegrityVerifier, "decode", fake_decode)
    files = {"audio": ("s.aac", audio, "audio/aac")}
    ok = await client.post("/v1/recognitions", files=files, data={"session_id": "sess-1"},
                           headers={"X-Integrity-Token": expected})
    assert ok.status_code == 200
    bad = await client.post("/v1/recognitions", files=files, data={"session_id": "sess-1"},
                            headers={"X-Integrity-Token": "some-other-hash"})
    assert bad.status_code == 403 and bad.json()["detail"] == "request_hash_mismatch"


async def test_links_stream_and_cache(client, deezer):
    track_id = (await recognize(client, wav_bytes(1.0))).json()["candidates"][0]["track"]["id"]
    resp = await client.get(f"/v1/tracks/{track_id}/links?country=vn")
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/event-stream")
    events = parse_sse(resp.text)
    assert events[0][0] == "track" and events[-1][0] == "done"
    link_events = [data for name, data in events if name == "links"]
    adapters = {e["adapter"] for e in link_events}
    assert adapters == {"youtube", "youtube_music", "spotify", "deezer", "zing_mp3", "nct", "bandcamp", "cc_search"}
    links = [l for e in link_events for l in e["links"]]
    zing = [l for l in links if l["platform"] == "zing_mp3"]
    assert {l["kind"] for l in zing} == {"listen", "offline_in_app"}
    assert all(l["match"] == "search" and l["url"].startswith("https://zingmp3.vn/") for l in zing)
    assert all(l["id"].startswith("lnk_") for l in links)
    assert events[-1][1]["count"] == len(links)

    again = parse_sse((await client.get(f"/v1/tracks/{track_id}/links?country=VN")).text)
    assert all(data["cached"] for name, data in again if name == "links")


async def test_links_json_mode_sorted_and_beat_variant(client):
    rec = (await recognize(client, wav_bytes(1.0))).json()
    track_id = rec["candidates"][0]["track"]["id"]
    body = (await client.get(f"/v1/tracks/{track_id}/links", params={"stream": "false", "variant": "beat"})).json()
    kinds = [l["kind"] for l in body["links"]]
    order = {"listen": 0, "buy": 1, "free_download": 2, "offline_in_app": 3}
    assert kinds == sorted(kinds, key=order.get)
    assert any("beat" in l["url"] for l in body["links"] if l["platform"] == "youtube")


async def test_links_use_engine_ids(make_client, settings):
    from app.recognition.base import EngineMatch, TrackMeta

    def customize(services):
        async def run(audio, filename, *, mode, stage):
            from app.recognition.cascade import CascadeOutcome
            meta = TrackMeta(title="Nơi Này Có Anh", artists=["Sơn Tùng M-TP"], duration_ms=260000,
                             isrc="VNA0Z1700001", artwork_url="https://img/x.jpg",
                             external_ids={"spotify": "sp1", "youtube": "yt1", "deezer": "dz1"})
            return CascadeOutcome(status="matched", engine="acrcloud", matches=[EngineMatch(meta, 1.0, "acrcloud")])
        services.cascade.run = run

    client = await make_client(settings, customize)
    track_id = (await recognize(client)).json()["candidates"][0]["track"]["id"]
    body = (await client.get(f"/v1/tracks/{track_id}/links", params={"stream": "false"})).json()
    exact = {(l["platform"], l["kind"]): l["url"] for l in body["links"] if l["match"] == "exact"}
    assert exact[("spotify", "listen")] == "https://open.spotify.com/track/sp1"
    assert exact[("spotify", "offline_in_app")] == "https://open.spotify.com/track/sp1"
    assert exact[("youtube", "listen")] == "https://www.youtube.com/watch?v=yt1"
    assert exact[("youtube_music", "listen")] == "https://music.youtube.com/watch?v=yt1"
    assert exact[("deezer", "listen")] == "https://www.deezer.com/track/dz1"


async def test_adapter_failure_degrades_to_search_link(client, deezer):
    deezer.get(DEEZER_SEARCH).mock(side_effect=httpx.ConnectError("boom"))
    rec = (await recognize(client, wav_bytes(1.0))).json()
    track_id = rec["candidates"][0]["track"]["id"]
    events = parse_sse((await client.get(f"/v1/tracks/{track_id}/links")).text)
    dz = next(data for name, data in events if name == "links" and data["adapter"] == "deezer")
    assert dz["degraded"] is True
    assert dz["links"][0]["match"] == "search" and dz["links"][0]["url"].startswith("https://www.deezer.com/search/")


async def test_report_violation_hides_link(client):
    rec = (await recognize(client, wav_bytes(1.0))).json()
    track_id = rec["candidates"][0]["track"]["id"]
    body = (await client.get(f"/v1/tracks/{track_id}/links", params={"stream": "false"})).json()
    target = body["links"][0]

    resp = await client.post(f"/v1/links/{target['id']}/report", json={"reason": "violation"})
    assert resp.status_code == 202 and resp.json() == {"hidden": True}
    # Hidden even when served from the cache.
    body = (await client.get(f"/v1/tracks/{track_id}/links", params={"stream": "false"})).json()
    assert target["id"] not in {l["id"] for l in body["links"]}

    resp = await client.post("/v1/links/lnk_missing/report", json={"reason": "broken"})
    assert resp.status_code == 404


async def test_wrong_link_reports_hide_after_threshold(make_client, settings):
    client = await make_client(settings.model_copy(update={"report_hide_threshold": 2}))
    rec = (await recognize(client, wav_bytes(1.0))).json()
    track_id = rec["candidates"][0]["track"]["id"]
    link = (await client.get(f"/v1/tracks/{track_id}/links", params={"stream": "false"})).json()["links"][0]
    url = f"/v1/links/{link['id']}/report"
    assert (await client.post(url, json={"reason": "wrong_song"})).json() == {"hidden": False}
    # Same device again: ignored.
    assert (await client.post(url, json={"reason": "wrong_song"})).json() == {"hidden": False}
    resp = await client.post(url, json={"reason": "broken"}, headers={"X-Device-Id": "second-device-1"})
    assert resp.json() == {"hidden": True}
    async with client.app.state.services.db.sessionmaker() as s:
        assert (await s.get(TrackLink, link["id"])).hidden


async def test_recognition_report(client):
    rec = (await recognize(client)).json()
    resp = await client.post(f"/v1/recognitions/{rec['id']}/report", json={"reason": "wrong_song"})
    assert resp.status_code == 202
    resp = await client.post(f"/v1/recognitions/{rec['id']}/report", json={"reason": "wrong_song"},
                             headers={"X-Device-Id": "someone-else-1"})
    assert resp.status_code == 404


async def test_search(client, deezer):
    deezer.get(DEEZER_SEARCH).respond(json={"data": [
        {"id": 3135556, "title": "Harder, Better, Faster, Stronger", "duration": 224,
         "artist": {"name": "Daft Punk"}, "album": {"title": "Discovery", "cover_xl": "https://img/df.jpg"}},
    ]})
    resp = await client.get("/v1/search", params={"q": "harder better"})
    assert resp.status_code == 200
    [result] = resp.json()["results"]
    assert result["title"] == "Harder, Better, Faster, Stronger" and result["artwork_url"] == "https://img/df.jpg"
    body = (await client.get(f"/v1/tracks/{result['id']}/links", params={"stream": "false"})).json()
    dz = next(l for l in body["links"] if l["platform"] == "deezer")
    assert dz["url"] == "https://www.deezer.com/track/3135556" and dz["match"] == "exact"


async def test_config(client):
    body = (await client.get("/v1/config")).json()
    assert body["quota_per_day"] == 30 and body["sample"]["early_probe_s"] == 6
    platforms = {p["id"]: p for p in body["platforms"]}
    assert platforms["zing_mp3"]["enabled"] and platforms["zing_mp3"]["android_package"] == "com.zing.mp3"
    assert not platforms["soundcloud"]["enabled"]  # adapter not enabled in the test settings
    assert {r["id"] for r in body["report_reasons"]} == {"wrong_song", "broken", "violation", "other"}


async def test_admin_moderation(make_client, settings):
    client = await make_client(settings.model_copy(update={"admin_token": "s3cret"}))
    rec = (await recognize(client, wav_bytes(1.0))).json()
    track_id = rec["candidates"][0]["track"]["id"]
    link = (await client.get(f"/v1/tracks/{track_id}/links", params={"stream": "false"})).json()["links"][0]
    await client.post(f"/v1/links/{link['id']}/report", json={"reason": "violation"})

    assert (await client.get("/admin/reports")).status_code == 401
    reports = (await client.get("/admin/reports", headers={"X-Admin-Token": "s3cret"})).json()
    assert reports[0]["link"]["id"] == link["id"] and reports[0]["link"]["hidden"]
    resp = await client.post(f"/admin/links/{link['id']}/resolve", json={"action": "restore"},
                             headers={"X-Admin-Token": "s3cret"})
    assert resp.json() == {"id": link["id"], "hidden": False}
    assert (await client.get("/admin/reports", headers={"X-Admin-Token": "s3cret"})).json() == []


def test_demo_mode_refused_in_production():
    from app.main import create_app
    with pytest.raises(RuntimeError):
        create_app(Settings(_env_file=None, environment="production", demo_mode=True))
