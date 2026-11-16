"""Hạn mức theo lượt chạm: không lách được bằng cách dùng lại session_id, và hoàn lượt khi engine lỗi."""

from __future__ import annotations

import httpx

from app.recognition.base import EngineMatch, TrackMeta
from app.recognition.cascade import CascadeOutcome, EnginesUnavailable
from tests.conftest import adts_stream

MATCH = EngineMatch(TrackMeta(title="Bài Thử", artists=["Ca Sĩ"], isrc="VNA0Z2600001",
                              artwork_url="https://img.test/a.jpg"), 0.97, "acrcloud")


async def recognize(client: httpx.AsyncClient, **form) -> httpx.Response:
    files = {"audio": ("sample.aac", adts_stream(6.0), "audio/aac")}
    return await client.post("/v1/recognitions", files=files, data={"mode": "auto", "source": "mic", **form})


def scripted_cascade(script):
    """``script(stage, call_no)`` returns a CascadeOutcome or raises; replaces the engine cascade."""
    calls = {"n": 0}

    def customize(services):
        async def run(audio, filename, *, mode, stage):
            calls["n"] += 1
            result = script(stage, calls["n"])
            if isinstance(result, Exception):
                raise result
            return result
        services.cascade.run = run

    return customize


def matched() -> CascadeOutcome:
    return CascadeOutcome(status="matched", engine="acrcloud", matches=[MATCH])


def keep_listening() -> CascadeOutcome:
    return CascadeOutcome(status="no_match", engine="acrcloud", final=False)


def outage() -> EnginesUnavailable:
    return EnginesUnavailable("acrcloud request failed: timeout")


async def remaining(client: httpx.AsyncClient, session_id: str) -> int:
    """Quota left after one more successful tap under a fresh session."""
    resp = await recognize(client, stage="full", session_id=session_id)
    assert resp.status_code == 200, resp.text
    return int(resp.headers["X-Quota-Remaining"])


async def test_replaying_a_session_id_costs_a_unit_each_time(make_client, settings):
    """Trước đây mọi yêu cầu dùng lại session_id trong 1 giờ đều miễn phí: hạn mức 30 lượt/ngày vô tác dụng."""
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 3}),
                               scripted_cascade(lambda stage, n: matched()))
    seen = [(await recognize(client, stage="full", session_id="same")) for _ in range(4)]
    assert [r.status_code for r in seen] == [200, 200, 200, 429]
    assert [r.headers["X-Quota-Remaining"] for r in seen] == ["2", "1", "0", "0"]


async def test_probe_plus_full_sample_is_one_tap_but_only_once(make_client, settings):
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 3}),
                               scripted_cascade(lambda stage, n: keep_listening() if stage == "early" else matched()))
    assert (await recognize(client, stage="early", session_id="tap")).headers["X-Quota-Remaining"] == "2"
    assert (await recognize(client, stage="full", session_id="tap")).headers["X-Quota-Remaining"] == "2"
    # A third and fourth sample under the same id are new taps, whatever their stage.
    assert (await recognize(client, stage="full", session_id="tap")).headers["X-Quota-Remaining"] == "1"
    assert (await recognize(client, stage="early", session_id="tap")).headers["X-Quota-Remaining"] == "0"
    assert (await recognize(client, stage="early", session_id="tap")).status_code == 429


async def test_two_probes_do_not_share_a_unit(make_client, settings):
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 3}),
                               scripted_cascade(lambda stage, n: keep_listening()))
    assert (await recognize(client, stage="early", session_id="tap")).headers["X-Quota-Remaining"] == "2"
    assert (await recognize(client, stage="early", session_id="tap")).headers["X-Quota-Remaining"] == "1"


async def test_engine_outage_gives_the_unit_back(make_client, settings):
    """HANDOFF mục 7.6: lượt vẫn bị trừ khi mọi engine lỗi và API trả 503."""
    script = iter([outage(), outage(), outage(), matched()])
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 5}),
                               scripted_cascade(lambda stage, n: next(script)))
    for session in ("a", "b", None):
        form = {"stage": "full"} if session is None else {"stage": "full", "session_id": session}
        resp = await recognize(client, **form)
        assert resp.status_code == 503 and resp.json()["error"] == "engines_unavailable"
    # Three failed taps cost nothing: this one is the first unit of the day.
    assert await remaining(client, "c") == 4


async def test_outage_on_the_full_sample_refunds_the_tap_paid_by_the_probe(make_client, settings):
    script = iter([keep_listening(), outage(), matched()])
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 2}),
                               scripted_cascade(lambda stage, n: next(script)))
    assert (await recognize(client, stage="early", session_id="tap")).headers["X-Quota-Remaining"] == "1"
    assert (await recognize(client, stage="full", session_id="tap")).status_code == 503
    assert await remaining(client, "next") == 1


async def test_retry_under_the_same_session_after_a_refund_is_charged_once(make_client, settings):
    """Hàng chờ offline gửi lại mẫu với cùng session_id: lần lỗi được hoàn, lần thành công tính một lượt."""
    script = iter([outage(), outage(), matched(), matched()])
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 3}),
                               scripted_cascade(lambda stage, n: next(script)))
    assert (await recognize(client, stage="full", session_id="pending-1")).status_code == 503
    assert (await recognize(client, stage="full", session_id="pending-1")).status_code == 503
    assert (await recognize(client, stage="full", session_id="pending-1")).headers["X-Quota-Remaining"] == "2"
    assert await remaining(client, "other") == 1


async def test_no_refund_once_the_tap_already_got_its_answer(make_client, settings):
    """Mẫu 6 s đã khớp: gửi thêm một mẫu "full" làm engine lỗi không được đổi lại lượt đã dùng."""
    script = iter([matched(), outage(), matched()])
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 2}),
                               scripted_cascade(lambda stage, n: next(script)))
    assert (await recognize(client, stage="early", session_id="tap")).headers["X-Quota-Remaining"] == "1"
    assert (await recognize(client, stage="full", session_id="tap")).status_code == 503
    assert await remaining(client, "next") == 0


async def test_refunds_are_capped_per_day(make_client, settings):
    """Hoàn lượt không được thành đường gọi engine miễn phí vô hạn: tối đa bằng hạn mức mỗi ngày."""
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 2}),
                               scripted_cascade(lambda stage, n: outage()))
    codes = [(await recognize(client, stage="full", session_id=f"s{i}")).status_code for i in range(6)]
    # 2 refunded failures, then 2 failures that keep their units, then the quota is gone.
    assert codes == [503, 503, 503, 503, 429, 429]


async def test_unexpected_engine_crash_gives_the_unit_back(make_client, settings):
    script = iter([RuntimeError("boom"), matched()])
    client = await make_client(settings.model_copy(update={"quota_per_device_per_day": 2}),
                               scripted_cascade(lambda stage, n: next(script)))
    resp = await recognize(client, stage="full", session_id="x")
    assert resp.status_code == 503 and resp.json()["error"] == "engines_unavailable"
    assert await remaining(client, "y") == 1
