"""Kiểm thử khói qua HTTP thật trên một backend đang chạy ở DEMO_MODE=true.

Bộ pytest chạy với SQLite và bộ nhớ đệm trong tiến trình; script này đi đúng đường của bản
triển khai: uvicorn + PostgreSQL + Redis. Không cần khoá API và không gọi dịch vụ ngoài trực
tiếp (các adapter tự lùi về link tìm kiếm khi không ra được mạng).

    DATABASE_URL=postgresql+asyncpg://... REDIS_URL=redis://... DEMO_MODE=true \\
      ADMIN_TOKEN=<token> QUOTA_PER_DEVICE_PER_DAY=5 SEARCH_PER_DEVICE_PER_DAY=3 \\
      uvicorn app.main:app --port 8000
    python tests/live/smoke.py --base-url http://127.0.0.1:8000 --admin-token <token>

In PASS/FAIL từng bước, thoát mã khác 0 khi có bước đỏ. ``--only tên1,tên2`` chạy riêng vài
bước; bộ lọc không khớp bước nào là lỗi.

Bước ``concurrent_requests_do_not_collide`` chỉ bắt được tranh chấp "lần đầu lưu một bài" khi
bảng ``track`` chưa có ba bài mẫu của chế độ demo: xoá dữ liệu (TRUNCATE track CASCADE, FLUSHALL
Redis) rồi chạy riêng bước đó, lặp vài lần.
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Callable

import httpx

STEPS: list[tuple[str, Callable[["Ctx"], None]]] = []


def step(fn: Callable[["Ctx"], None]) -> Callable[["Ctx"], None]:
    STEPS.append((fn.__name__, fn))
    return fn


def adts(seconds: float, seed: int = 0) -> bytes:
    """Synthetic ADTS AAC stream: valid headers, payload derived from ``seed`` (demo mode picks the track from it)."""
    payload = bytes([seed % 251]) * 20
    frame_len = len(payload) + 7
    header = bytes([0xFF, 0xF1, (1 << 6) | (4 << 2), (1 << 6) | ((frame_len >> 11) & 3),
                    (frame_len >> 3) & 0xFF, ((frame_len & 7) << 5) | 0x1F, 0xFC])
    return (header + payload) * int(seconds * 44100 / 1024)


class Ctx:
    def __init__(self, base_url: str, admin_token: str, quota: int, search_quota: int = 3):
        self.base_url = base_url.rstrip("/")
        self.admin_token = admin_token
        self.quota = quota
        self.search_quota = search_quota
        self.http = httpx.Client(base_url=self.base_url, timeout=60.0, trust_env=False)

    @staticmethod
    def device() -> str:
        return "smoke-" + secrets.token_hex(8)

    def recognize(self, device: str, audio: bytes | None = None, **form) -> httpx.Response:
        files = {"audio": ("sample.aac", audio if audio is not None else adts(12.0), "audio/aac")}
        return self.http.post("/v1/recognitions", files=files, data={"mode": "auto", "source": "mic", **form},
                              headers={"X-Device-Id": device, "X-App-Version": "1.0.0"})

    def track(self, device: str, seed: int = 0) -> str:
        resp = self.recognize(device, adts(6.0, seed))
        assert resp.status_code == 200, resp.text
        return resp.json()["candidates"][0]["track"]["id"]


def sse_events(text: str) -> list[tuple[str, dict]]:
    events = []
    for block in text.strip().split("\n\n"):
        fields = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line)
        events.append((fields["event"], json.loads(fields["data"])))
    return events


@step
def health_and_config(c: Ctx) -> None:
    assert c.http.get("/healthz").json() == {"status": "ok"}
    cfg = c.http.get("/v1/config").json()
    assert cfg["demo_mode"] is True, "the backend must run with DEMO_MODE=true"
    assert cfg["quota_per_day"] == c.quota, f"start the backend with QUOTA_PER_DEVICE_PER_DAY={c.quota}"
    assert {"youtube", "spotify", "zing_mp3", "nct"} <= {p["id"] for p in cfg["platforms"]}
    for secret in ("key", "secret", "token", "password"):
        assert not any(secret in k.lower() for k in json.dumps(cfg).split('"') if k.endswith("_" + secret)), cfg


@step
def recognition_and_tap_quota(c: Ctx) -> None:
    d = c.device()
    probe = c.recognize(d, adts(6.0), stage="early", session_id="tap-1")
    full = c.recognize(d, adts(12.0), stage="full", session_id="tap-1")
    assert probe.status_code == full.status_code == 200, (probe.text, full.text)
    body = full.json()
    assert body["status"] == "matched" and body["candidates"][0]["track"]["id"].startswith("trk_")
    assert probe.headers["X-Quota-Remaining"] == full.headers["X-Quota-Remaining"] == str(c.quota - 1)
    # Replaying the session id is a new tap each time.
    replay = c.recognize(d, adts(12.0), stage="full", session_id="tap-1")
    assert replay.headers["X-Quota-Remaining"] == str(c.quota - 2), replay.headers
    hum = c.recognize(d, mode="hum", source="hum", session_id="tap-2").json()
    assert hum["status"] == "candidates" and len(hum["candidates"]) == 3
    assert all(x["flags"] == ["melody"] for x in hum["candidates"])


@step
def quota_runs_out_with_429(c: Ctx) -> None:
    d = c.device()
    codes = [c.recognize(d, session_id=f"s{i}").status_code for i in range(c.quota + 2)]
    assert codes == [200] * c.quota + [429, 429], codes
    last = c.recognize(d, session_id="again")
    assert last.json()["error"] == "quota_exceeded" and last.headers["X-Quota-Remaining"] == "0"
    assert c.recognize(c.device()).status_code == 200, "another device has its own quota"


@step
def bad_requests_are_4xx(c: Ctx) -> None:
    d = c.device()
    cases = {
        "garbage": (b"garbage-garbage-garbage", 422),
        "empty": (b"", 422),
        "truncated wav": (b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00", 422),
        "20 s of audio": (adts(20.0), 422),
        "3 MB": (b"\xff\xf1" + b"\x00" * 3_000_000, (413, 422)),
    }
    for name, (audio, expected) in cases.items():
        resp = c.recognize(d, audio)
        ok = resp.status_code in (expected if isinstance(expected, tuple) else (expected,))
        assert ok, f"{name}: {resp.status_code} {resp.text[:200]}"
    assert c.recognize("bad id!").status_code == 400
    assert c.http.post("/v1/recognitions", files={"audio": ("s.aac", adts(5), "audio/aac")}).status_code == 400
    assert c.recognize(d, stage="later").status_code == 422
    assert c.recognize(d, session_id="x" * 65).status_code == 422
    assert c.http.get("/v1/tracks/trk_missing/links", headers={"X-Device-Id": d}).status_code == 404
    tid = c.track(d)
    assert c.http.get(f"/v1/tracks/{tid}/links", params={"country": "VNM"},
                      headers={"X-Device-Id": d}).status_code == 422
    assert c.http.get("/v1/does-not-exist").status_code == 404


@step
def links_stream_then_cache(c: Ctx) -> None:
    d = c.device()
    tid = c.track(d, seed=1)
    started = time.monotonic()
    resp = c.http.get(f"/v1/tracks/{tid}/links", params={"country": "vn"}, headers={"X-Device-Id": d})
    took = time.monotonic() - started
    assert resp.status_code == 200 and resp.headers["content-type"].startswith("text/event-stream")
    events = sse_events(resp.text)
    assert events[0][0] == "track" and events[-1][0] == "done", [e[0] for e in events]
    links = [l for name, data in events if name == "links" for l in data["links"]]
    assert links and events[-1][1]["count"] == len(links)
    assert all(l["url"].startswith("https://") and l["id"].startswith("lnk_") for l in links), links
    assert {"zing_mp3", "nct", "youtube", "spotify"} <= {l["platform"] for l in links}
    assert took < 10, f"every adapter is bounded by its timeout, the stream took {took:.1f} s"
    started = time.monotonic()
    again = c.http.get(f"/v1/tracks/{tid}/links", params={"stream": "false"}, headers={"X-Device-Id": d})
    assert again.status_code == 200 and time.monotonic() - started < 2, "second call is served from the cache"
    assert {l["id"] for l in again.json()["links"]} == {l["id"] for l in links}
    kinds = [l["kind"] for l in again.json()["links"]]
    order = {"listen": 0, "buy": 1, "free_download": 2, "offline_in_app": 3}
    assert kinds == sorted(kinds, key=order.get)


@step
def concurrent_requests_do_not_collide(c: Ctx) -> None:
    """Same new track recognised by 8 devices at once, then its links opened by 8 devices at once."""
    seed = secrets.randbelow(10_000) * 3 + 2  # demo mode: seed picks one of the three canned tracks
    audio = adts(6.0, seed)
    with ThreadPoolExecutor(8) as pool:
        recs = list(pool.map(lambda _: Ctx(c.base_url, c.admin_token, c.quota).recognize(Ctx.device(), audio), range(8)))
    assert [r.status_code for r in recs] == [200] * 8, [r.text[:120] for r in recs if r.status_code != 200]
    ids = {r.json()["candidates"][0]["track"]["id"] for r in recs}
    assert len(ids) == 1, f"one recording must be one track row, got {ids}"
    tid = ids.pop()

    def links(_: int) -> httpx.Response:
        with httpx.Client(base_url=c.base_url, timeout=60.0, trust_env=False) as http:
            return http.get(f"/v1/tracks/{tid}/links", params={"stream": "false", "country": "SG"},
                            headers={"X-Device-Id": Ctx.device()})

    with ThreadPoolExecutor(8) as pool:
        got = list(pool.map(links, range(8)))
    assert [r.status_code for r in got] == [200] * 8, [r.text[:200] for r in got if r.status_code != 200]
    sets = [frozenset(l["id"] for l in r.json()["links"]) for r in got]
    assert len(set(sets)) == 1 and sets[0], "every caller sees the same stored links"


@step
def reports_and_moderation(c: Ctx) -> None:
    d = c.device()
    rec = c.recognize(d, adts(6.0, 5)).json()
    tid = rec["candidates"][0]["track"]["id"]
    headers = {"X-Device-Id": d}
    links = c.http.get(f"/v1/tracks/{tid}/links", params={"stream": "false", "country": "TH"}, headers=headers).json()["links"]
    target = links[0]
    resp = c.http.post(f"/v1/links/{target['id']}/report", json={"reason": "violation"}, headers=headers)
    assert resp.status_code == 202 and resp.json() == {"hidden": True}
    after = c.http.get(f"/v1/tracks/{tid}/links", params={"stream": "false", "country": "TH"}, headers=headers).json()["links"]
    assert target["id"] not in {l["id"] for l in after}, "hidden even when served from the cache"
    assert c.http.post("/v1/links/lnk_missing/report", json={"reason": "broken"}, headers=headers).status_code == 404
    assert c.http.post(f"/v1/links/{target['id']}/report", json={"reason": "nope"}, headers=headers).status_code == 422
    assert c.http.post(f"/v1/recognitions/{rec['id']}/report", json={"reason": "wrong_song"}, headers=headers).status_code == 202
    assert c.http.post(f"/v1/recognitions/{rec['id']}/report", json={"reason": "wrong_song"},
                       headers={"X-Device-Id": c.device()}).status_code == 404

    assert c.http.get("/admin/reports").status_code == 401
    assert c.http.get("/admin/reports", headers={"X-Admin-Token": "wrong"}).status_code == 401
    assert c.http.get("/admin/reports", headers={"X-Admin-Token": "sécret".encode("latin-1")}).status_code == 401
    admin = {"X-Admin-Token": c.admin_token}
    reports = c.http.get("/admin/reports", headers=admin)
    assert reports.status_code == 200, "pass --admin-token matching the backend's ADMIN_TOKEN"
    assert any(r["link"]["id"] == target["id"] and r["link"]["hidden"] for r in reports.json())
    restored = c.http.post(f"/admin/links/{target['id']}/resolve", json={"action": "restore"}, headers=admin)
    assert restored.json() == {"id": target["id"], "hidden": False}
    back = c.http.get(f"/v1/tracks/{tid}/links", params={"stream": "false", "country": "TH"}, headers=headers).json()["links"]
    assert target["id"] in {l["id"] for l in back}


@step
def search_answers_and_is_rate_limited(c: Ctx) -> None:
    d = c.device()
    assert c.http.get("/v1/search", params={"q": "x"}, headers={"X-Device-Id": d}).status_code == 422
    resp = c.http.get("/v1/search", params={"q": "nơi này có anh"}, headers={"X-Device-Id": d})
    assert resp.status_code == 200 and isinstance(resp.json()["results"], list)
    # Each search may call the public catalogues: keep the number of calls small.
    codes = [c.http.get("/v1/search", params={"q": "bohemian"}, headers={"X-Device-Id": d}).status_code
             for _ in range(c.search_quota + 1)]
    assert codes[:c.search_quota - 1] == [200] * (c.search_quota - 1), codes
    assert codes[-2:] == [429, 429], f"start the backend with SEARCH_PER_DEVICE_PER_DAY={c.search_quota}: {codes}"


@step
def closing_a_stream_early_leaves_the_server_healthy(c: Ctx) -> None:
    d = c.device()
    tid = c.track(d, seed=7)
    for _ in range(5):
        with httpx.Client(base_url=c.base_url, timeout=30.0, trust_env=False) as http:
            with http.stream("GET", f"/v1/tracks/{tid}/links", params={"country": "KR"},
                             headers={"X-Device-Id": d}) as resp:
                assert resp.status_code == 200
                next(resp.iter_lines())  # read the first event, then hang up
    assert c.http.get("/healthz").status_code == 200
    done = sse_events(c.http.get(f"/v1/tracks/{tid}/links", params={"country": "KR"}, headers={"X-Device-Id": d}).text)
    assert done[-1][0] == "done"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--admin-token", default="")
    parser.add_argument("--quota", type=int, default=5, help="QUOTA_PER_DEVICE_PER_DAY the backend runs with")
    parser.add_argument("--search-quota", type=int, default=3, help="SEARCH_PER_DEVICE_PER_DAY the backend runs with")
    parser.add_argument("--only", default="", help="comma-separated step names")
    args = parser.parse_args()

    wanted = [s for s in args.only.split(",") if s]
    unknown = [s for s in wanted if s not in dict(STEPS)]
    if unknown:
        print(f"FAIL  unknown step(s): {', '.join(unknown)}; available: {', '.join(n for n, _ in STEPS)}")
        return 2
    selected = [(n, f) for n, f in STEPS if not wanted or n in wanted]
    failed = 0
    for name, fn in selected:
        ctx = Ctx(args.base_url, args.admin_token, args.quota, args.search_quota)
        started = time.monotonic()
        try:
            fn(ctx)
            print(f"PASS  {name}  ({time.monotonic() - started:.1f} s)")
        except Exception as exc:  # noqa: BLE001 - report every step
            failed += 1
            print(f"FAIL  {name}  ({time.monotonic() - started:.1f} s): {type(exc).__name__}: {exc}")
        finally:
            ctx.http.close()
    print(f"{len(selected) - failed}/{len(selected)} steps passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
