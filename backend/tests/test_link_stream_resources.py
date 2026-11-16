"""Luồng link không được giữ kết nối CSDL trong lúc chờ adapter, và chịu được việc client ngắt giữa chừng."""

from __future__ import annotations

import asyncio
import logging

import anyio
import httpx
import pytest

from app.cache import MemoryCache
from app.db import Database
from app.links.base import EXACT, LISTEN, Adapter, LinkOut
from app.links.circuit import BreakerRegistry
from app.links.resolver import LinkResolver
from app.models import Track
from tests.conftest import wav_bytes


class SlowAdapter(Adapter):
    """Stands for a platform API that takes a while (real adapters may use their full 3 s)."""

    name = "slow"
    platforms = ("youtube",)

    def __init__(self, delay_s: float, probe=None):
        self.delay_s, self.probe = delay_s, probe

    async def resolve(self, ctx):
        if self.probe:
            self.probe()
        await asyncio.sleep(self.delay_s)
        return [LinkOut("youtube", LISTEN, EXACT, f"https://www.youtube.com/watch?v=abc{ctx.country}", "Song", 200000, 1.0)]


@pytest.fixture
async def http():
    async with httpx.AsyncClient() as client:
        yield client


async def small_pool_resolver(settings, http, adapter):
    db = Database(settings.database_url, pool_size=1, max_overflow=0, pool_timeout=0.5)
    await db.create_all()
    async with db.sessionmaker() as s:
        s.add(Track(id="trk_1", match_key="k", title="Song", artists=["A"]))
        await s.commit()
        track = await s.get(Track, "trk_1")
    resolver = LinkResolver(settings, http, MemoryCache(), db.sessionmaker, BreakerRegistry(5, 60), adapters=[adapter])
    return db, track, resolver


async def test_no_database_connection_is_held_while_adapters_run(make_client, settings):
    """Mỗi luồng SSE từng giữ 2 kết nối suốt thời gian chờ adapter: pool 10+20 cạn ở ~15 luồng đồng thời."""
    checked_out: list[int] = []

    def customize(services):
        services.resolver.adapters = [
            SlowAdapter(0.05, probe=lambda: checked_out.append(services.db.engine.pool.checkedout()))]

    client = await make_client(settings, customize)
    rec = await client.post("/v1/recognitions", files={"audio": ("s.wav", wav_bytes(1.0), "audio/wav")})
    tid = rec.json()["candidates"][0]["track"]["id"]
    stream = await client.get(f"/v1/tracks/{tid}/links")
    assert stream.status_code == 200 and "event: done" in stream.text
    once = await client.get(f"/v1/tracks/{tid}/links", params={"stream": "false", "country": "US"})
    assert once.status_code == 200 and len(once.json()["links"]) == 1
    assert checked_out == [0, 0]


async def test_many_streams_fit_in_a_pool_of_one(settings, http):
    db, track, resolver = await small_pool_resolver(settings, http, SlowAdapter(0.2))
    try:
        countries = ["VN", "US", "JP", "KR", "SG", "TH", "ID", "PH"]
        results = await asyncio.gather(*(resolver.resolve_all(track, c) for c in countries))
        assert [len(r) for r in results] == [1] * len(countries)
    finally:
        await db.dispose()


async def test_client_hanging_up_mid_stream_leaves_the_pool_clean(settings, http, caplog):
    """Starlette huỷ luồng bằng cancel scope của anyio: mọi await trong phần dọn dẹp đều bị huỷ lại."""
    db, track, resolver = await small_pool_resolver(settings, http, SlowAdapter(0.3))
    try:
        with caplog.at_level(logging.WARNING):
            for country in ("VN", "US", "JP"):
                with anyio.CancelScope() as scope:
                    stream = resolver.stream(track, country)
                    task = asyncio.ensure_future(stream.__anext__())
                    await asyncio.sleep(0.05)   # the adapter is running, the client goes away
                    scope.cancel()
                    await task
                assert scope.cancelled_caught or task.cancelled()
                await asyncio.sleep(0.05)
        pool_errors = [r.getMessage() for r in caplog.records if r.name.startswith("sqlalchemy")]
        assert pool_errors == []
        assert db.engine.pool.checkedout() == 0
        assert len(await resolver.resolve_all(track, "KR")) == 1  # the only connection still works
    finally:
        await db.dispose()
