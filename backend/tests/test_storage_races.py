"""Hai yêu cầu lưu cùng một bài/link cùng lúc, và giá trị không vừa cột PostgreSQL, không được thành 500."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone

import httpx
import pytest

from app.cache import MemoryCache
from app.config import Settings
from app.db import Database
from app.links.base import EXACT, LISTEN, Adapter, LinkOut
from app.links.circuit import BreakerRegistry
from app.links.resolver import LinkResolver
from app.models import Track, TrackLink
from app.recognition.base import TrackMeta
from app.services.tracks import lock_tracks, upsert_track
from app.text import match_key


@pytest.fixture
async def http():
    async with httpx.AsyncClient() as client:
        yield client


# --- two requests storing the same thing at the same time ----------------------------------

def _sqlite_path(settings: Settings) -> str:
    return settings.database_url.split("///", 1)[1]


async def test_upsert_track_survives_a_concurrent_insert_of_the_same_isrc(settings, monkeypatch):
    """Hai máy nhận diện cùng một bài mới cùng lúc: yêu cầu thứ hai từng vỡ ràng buộc UNIQUE(isrc) → 500."""
    from app.services import tracks as tracks_module

    db = Database(settings.database_url)
    await db.create_all()
    meta = TrackMeta(title="Bài Mới", artists=["Ca Sĩ"], isrc="VNA0Z2600009", album="Album Mới", duration_ms=200000)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")
    real_new_id = tracks_module.new_id

    def racing_new_id(prefix: str) -> str:
        # Another request commits the same recording between our SELECT and our INSERT.
        conn = sqlite3.connect(_sqlite_path(settings))
        conn.execute(
            "INSERT INTO track (id, isrc, match_key, title, artists, is_instrumental, genres, external_ids,"
            " created_at, updated_at) VALUES (?, ?, ?, ?, ?, 0, '[]', '{}', ?, ?)",
            ("trk_from_other_request", "VNA0Z2600009", match_key(meta.title, meta.artists), meta.title,
             '["Ca Sĩ"]', now, now))
        conn.commit()
        conn.close()
        return real_new_id(prefix)

    monkeypatch.setattr(tracks_module, "new_id", racing_new_id)
    try:
        async with db.sessionmaker() as s:
            track = await upsert_track(s, meta)
            await s.commit()
            assert track.id == "trk_from_other_request"
            assert track.album == "Album Mới"  # gaps of the existing row are still filled
        async with db.sessionmaker() as s:
            from sqlalchemy import func, select
            assert (await s.execute(select(func.count()).select_from(Track))).scalar_one() == 1
    finally:
        await db.dispose()


class OneLinkAdapter(Adapter):
    name = "one"
    platforms = ("youtube",)

    async def resolve(self, ctx):
        return [LinkOut("youtube", LISTEN, EXACT, "https://www.youtube.com/watch?v=abc", "Song", 200000, 1.0)]


async def test_link_persist_survives_a_concurrent_insert_of_the_same_link(settings, monkeypatch, http):
    """Hai người mở link của cùng một bài cùng lúc: luồng thứ hai từng vỡ UNIQUE(uq_track_link) giữa chừng SSE."""
    from app.links import resolver as resolver_module

    db = Database(settings.database_url)
    await db.create_all()
    async with db.sessionmaker() as s:
        s.add(Track(id="trk_1", match_key="k", title="Song", artists=["A"]))
        await s.commit()
        track = await s.get(Track, "trk_1")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")
    real_new_id = resolver_module.new_id

    def racing_new_id(prefix: str) -> str:
        conn = sqlite3.connect(_sqlite_path(settings))
        conn.execute(
            "INSERT INTO track_link (id, track_id, platform, url, kind, match, country, score, hidden,"
            " verified_at, created_at) VALUES (?, 'trk_1', 'youtube', ?, 'listen', 'exact', 'VN', 1.0, 0, ?, ?)",
            ("lnk_from_other_request", "https://www.youtube.com/watch?v=abc", now, now))
        conn.commit()
        conn.close()
        return real_new_id(prefix)

    monkeypatch.setattr(resolver_module, "new_id", racing_new_id)
    try:
        resolver = LinkResolver(settings, http, MemoryCache(), db.sessionmaker, BreakerRegistry(5, 60),
                                adapters=[OneLinkAdapter()])
        links = await resolver.resolve_all(track, "VN")
        assert [l["id"] for l in links] == ["lnk_from_other_request"]
        async with db.sessionmaker() as s:
            from sqlalchemy import func, select
            assert (await s.execute(select(func.count()).select_from(TrackLink))).scalar_one() == 1
    finally:
        await db.dispose()


class RecordingSession:
    """Just enough of a session to see what ``lock_tracks`` sends to PostgreSQL."""

    def __init__(self, dialect: str):
        self.bind = type("Bind", (), {"dialect": type("Dialect", (), {"name": dialect})()})()
        self.keys: list[str] = []

    async def execute(self, statement, params=None):
        assert "pg_advisory_xact_lock" in str(statement)
        self.keys.append(params["key"])


async def test_lock_tracks_takes_each_identity_once_in_sorted_order():
    metas = [TrackMeta(title="Zebra", artists=["B"]), TrackMeta(title="Alpha", artists=["A"], isrc="us-rc1-76-07839"),
             TrackMeta(title="zebra (Official Video)", artists=["b"]), TrackMeta(title="Alpha", artists=["A"])]
    pg = RecordingSession("postgresql")
    await lock_tracks(pg, metas)
    assert pg.keys == ["USRC17607839", "alpha|a", "zebra|b"]
    sqlite = RecordingSession("sqlite")
    await lock_tracks(sqlite, metas)
    assert sqlite.keys == []


# --- values that do not fit the PostgreSQL columns (SQLite does not check lengths) -------------

@pytest.mark.parametrize("raw,stored", [
    ("us-rc1-76-07839", "USRC17607839"),
    (" usrc17607839 ", "USRC17607839"),
    ("NOT-AN-ISRC-AT-ALL-0000000000", None),
    ("../../user/me", None),
    ("", None),
])
async def test_isrc_is_normalised_or_dropped(settings, raw, stored):
    db = Database(settings.database_url)
    await db.create_all()
    try:
        async with db.sessionmaker() as s:
            track = await upsert_track(s, TrackMeta(title="Song", artists=["A"], isrc=raw,
                                                    release_date="2019-05-31T00:00:00Z plus a very long tail " * 3,
                                                    duration_ms=2 ** 40))
            await s.commit()
            assert track.isrc == stored
            assert len(track.release_date) <= 32
            assert track.duration_ms is None
    finally:
        await db.dispose()
