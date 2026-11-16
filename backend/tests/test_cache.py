"""Hợp đồng của Cache trên cả hai bản cài đặt: bộ nhớ (dev/test) và Redis thật (production).

Bản Redis chạy với ``redis-server`` cục bộ trên một cổng tạm; máy không có ``redis-server``
thì các ca "redis" tự bỏ qua (hiện trong tổng kết của pytest), không gọi dịch vụ ngoài.
"""

from __future__ import annotations

import shutil
import socket
import subprocess
import time

import pytest

from app.cache import MemoryCache, RedisCache
from app.security.quota import consume, mark_served, refund


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def redis_url(tmp_path_factory):
    binary = shutil.which("redis-server")
    if not binary:
        pytest.skip("redis-server is not installed: RedisCache is not exercised on this machine")
    port = _free_port()
    proc = subprocess.Popen(
        [binary, "--port", str(port), "--bind", "127.0.0.1", "--save", "", "--appendonly", "no",
         "--dir", str(tmp_path_factory.mktemp("redis"))],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 10
        while True:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                if proc.poll() is not None or time.monotonic() > deadline:
                    pytest.skip("redis-server did not start")
                time.sleep(0.05)
        yield f"redis://127.0.0.1:{port}/0"
    finally:
        proc.terminate()
        proc.wait(timeout=10)


@pytest.fixture(params=["memory", "redis"])
async def cache(request):
    if request.param == "memory":
        instance = MemoryCache()
    else:
        instance = RedisCache(request.getfixturevalue("redis_url"))
        await instance._r.flushdb()
    yield instance
    await instance.close()


async def test_counters(cache):
    assert await cache.incr("n", 60) == 1
    assert await cache.incr("n", 60) == 2
    assert await cache.decr("n") == 1
    assert await cache.decr("n") == 0
    # Never negative, and a missing counter is not created.
    assert await cache.decr("n") == 0
    assert await cache.decr("missing") == 0
    assert await cache.get("missing") is None
    assert await cache.incr("n", 60) == 1


async def test_decr_keeps_the_expiry(cache):
    await cache.incr("n", 1)
    await cache.incr("n", 1)
    assert await cache.decr("n") == 1
    await _expire(cache, "n")
    assert await cache.get("n") is None


async def _expire(cache, key: str) -> None:
    """Wait until a 1 s key is gone (at most ~2.5 s); fails the test instead of hanging."""
    deadline = time.monotonic() + 2.5
    while await cache.get(key) is not None:
        assert time.monotonic() < deadline, f"{key} did not expire: decr dropped its TTL"
        time.sleep(0.05)


async def test_set_nx_get_set_delete_and_json(cache):
    assert await cache.set_nx("k", "a", 60) is True
    assert await cache.set_nx("k", "b", 60) is False
    assert await cache.get("k") == "a"
    await cache.set("k", "c", 60)
    assert await cache.get("k") == "c"
    await cache.delete("k")
    assert await cache.get("k") is None
    await cache.set_json("j", {"tên": ["Nơi Này Có Anh"], "n": 1}, 60)
    assert await cache.get_json("j") == {"tên": ["Nơi Này Có Anh"], "n": 1}
    assert await cache.get_json("nope") is None


async def test_quota_flow_on_this_cache(cache):
    async def tap(session, stage="full", limit=3):
        return await consume(cache, device_id="device-0001", session_id=session, stage=stage, limit=limit)

    probe = await tap("t1", "early")
    assert (probe.allowed, probe.remaining, probe.charged) == (True, 2, True)
    full = await tap("t1", "full")
    assert (full.allowed, full.remaining, full.charged) == (True, 2, False)
    replay = await tap("t1", "full")
    assert (replay.allowed, replay.remaining, replay.charged) == (True, 1, True)

    # Every engine failed on the full sample of a fresh tap: the probe's unit comes back, once.
    probe2 = await tap("t2", "early")
    assert probe2.remaining == 0
    full2 = await tap("t2", "full")
    assert await refund(cache, device_id="device-0001", session_id="t2", quota=full2, limit=3) is True
    assert await refund(cache, device_id="device-0001", session_id="t2", quota=full2, limit=3) is False
    assert (await tap("t3")).remaining == 0

    # Over the limit: refused, and a refused tap has nothing to refund.
    denied = await tap("t4")
    assert denied.allowed is False
    assert await refund(cache, device_id="device-0001", session_id="t4", quota=denied, limit=3) is False
    assert (await tap("t4", "full")).allowed is False


async def test_no_refund_after_the_tap_was_answered(cache):
    probe = await consume(cache, device_id="device-0002", session_id="t", stage="early", limit=5)
    await mark_served(cache, device_id="device-0002", session_id="t")
    full = await consume(cache, device_id="device-0002", session_id="t", stage="full", limit=5)
    assert probe.charged and full.allowed and not full.charged
    assert await refund(cache, device_id="device-0002", session_id="t", quota=full, limit=5) is False
