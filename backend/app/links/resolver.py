"""Link resolver (section 6, "Thuật toán").

1. Inputs: ISRC, title, artists, duration and platform ids from recognition.
2. Per-adapter cache keyed by ISRC (or track id) and country; hits are returned at once.
3. Adapters run in parallel, each bounded by a timeout (3 s by default) and a circuit breaker.
4. Name-based results are scored inside each adapter; below the threshold → rejected.
5. No API / quota spent / failure → deep search link labelled "Tìm trên …".
6. Each adapter's links are pushed to the app as soon as they are ready; exact
   results are cached 30 days, empty/search-only results 1 day.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..cache import Cache
from ..config import Settings
from ..db import insert_if_absent
from ..ids import new_id
from ..logsafe import redact
from ..models import Track, TrackLink
from ..services.tracks import positive_int32
from .adapters import build_adapters
from .base import EXACT, Adapter, LinkOut, QuotaExhausted, ResolveContext, TrackInfo, safe_link_url
from .circuit import BreakerRegistry

log = logging.getLogger(__name__)

KIND_ORDER = {"listen": 0, "buy": 1, "free_download": 2, "offline_in_app": 3}


@dataclass
class AdapterEvent:
    adapter: str
    links: list[dict[str, Any]] = field(default_factory=list)
    cached: bool = False
    degraded: bool = False


def track_info(track: Track) -> TrackInfo:
    return TrackInfo(
        id=track.id, title=track.title, artists=list(track.artists or []), duration_ms=track.duration_ms,
        isrc=track.isrc, is_instrumental=track.is_instrumental, work_title=track.work_title,
        genres=list(track.genres or []), external_ids=dict(track.external_ids or {}),
    )


def link_to_dict(row: TrackLink) -> dict[str, Any]:
    return {
        "id": row.id, "platform": row.platform, "kind": row.kind, "match": row.match, "url": row.url,
        "title": row.title, "duration_ms": row.duration_ms, "score": row.score, "license": row.license,
    }


def sort_links(links: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(links, key=lambda l: (KIND_ORDER.get(l["kind"], 9), l["match"] != EXACT, -(l.get("score") or 0)))


class LinkResolver:
    def __init__(self, settings: Settings, http: httpx.AsyncClient, cache: Cache,
                 sessionmaker: async_sessionmaker[AsyncSession], breakers: BreakerRegistry,
                 adapters: list[Adapter] | None = None):
        self.settings = settings
        self.http = http
        self.cache = cache
        self.sessionmaker = sessionmaker
        self.breakers = breakers
        self.adapters = adapters if adapters is not None else build_adapters(settings)

    def _cache_key(self, track: TrackInfo, country: str, variant: str | None, adapter: str) -> str:
        return f"links:v1:{track.cache_key}:{country}:{variant or '-'}:{adapter}"

    async def _run(self, adapter: Adapter, ctx: ResolveContext) -> tuple[list[LinkOut], bool]:
        links, degraded = await self._call(adapter, ctx)
        return self._only_web_links(adapter, links), degraded

    def _only_web_links(self, adapter: Adapter, links: list[LinkOut]) -> list[LinkOut]:
        """Single choke point: whatever an adapter returns, only http(s) links reach the app."""
        safe: list[LinkOut] = []
        for link in links:
            url = safe_link_url(link.url)
            if url is None:
                log.warning("adapter %s: dropped a %s link with an unsafe URL", adapter.name, link.kind)
                continue
            link.url = url
            safe.append(link)
        return safe

    def _fallback(self, adapter: Adapter, ctx: ResolveContext) -> list[LinkOut]:
        try:
            return adapter.fallback(ctx)
        except Exception as exc:  # noqa: BLE001 - e.g. a broken SEARCH_URL_OVERRIDES template
            log.error("adapter %s fallback failed: %s", adapter.name, redact(repr(exc)))
            return []

    async def _call(self, adapter: Adapter, ctx: ResolveContext) -> tuple[list[LinkOut], bool]:
        breaker = self.breakers.get(adapter.name)
        if not breaker.allow():
            return self._fallback(adapter, ctx), True
        timeout = adapter.timeout_s or self.settings.adapter_timeout_s
        try:
            links = await asyncio.wait_for(adapter.resolve(ctx), timeout)
            breaker.success()
            return links, False
        except QuotaExhausted as exc:
            log.info("%s: %s", adapter.name, exc)
            return self._fallback(adapter, ctx), True
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - any adapter failure degrades to its fallback
            breaker.failure()
            log.warning("adapter %s failed: %s", adapter.name, redact(repr(exc)))
            return self._fallback(adapter, ctx), True

    async def _persist(self, session: AsyncSession, track_id: str, country: str, links: list[LinkOut]) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        now = datetime.now(timezone.utc)
        for link in links:
            identity = dict(track_id=track_id, country=country, platform=link.platform, kind=link.kind, url=link.url)
            duration_ms = positive_int32(link.duration_ms)
            license_label = link.license[:128] if link.license else None
            # Two streams for the same track may store the same link at the same moment: the
            # second INSERT must not break the unique constraint (and with it the whole stream).
            await insert_if_absent(session, TrackLink, dict(
                identity, id=new_id("lnk"), match=link.match, title=link.title, duration_ms=duration_ms,
                score=link.score, license=license_label, verified_at=now), list(identity))
            row = (await session.execute(select(TrackLink).filter_by(**identity))).scalar_one()
            row.match, row.title, row.duration_ms = link.match, link.title, duration_ms
            row.score, row.license, row.verified_at = link.score, license_label, now
            await session.flush()
            if not row.hidden:
                out.append(link_to_dict(row))
        await session.commit()
        return out

    async def _hidden_ids(self, session: AsyncSession, track_id: str) -> set[str]:
        rows = await session.execute(select(TrackLink.id).where(TrackLink.track_id == track_id, TrackLink.hidden.is_(True)))
        return {r[0] for r in rows}

    async def _load_hidden(self, track_id: str) -> set[str]:
        async with self.sessionmaker() as session:
            return await self._hidden_ids(session, track_id)

    async def _store(self, track_id: str, country: str, links: list[LinkOut]) -> list[dict[str, Any]]:
        async with self.sessionmaker() as session:
            return await self._persist(session, track_id, country, links)

    @staticmethod
    async def _finish(coro: Any) -> Any:
        """Run a short database step to its end even if the request is cancelled meanwhile.

        A client that hangs up cancels the stream. Cancelling in the middle of a statement
        leaves the connection unusable: the pool has to destroy it (and logs an error with a
        traceback for every hang-up). The step is a few milliseconds, so let it finish and
        hand its connection back cleanly; the cancellation is still raised here.
        """
        task = asyncio.ensure_future(coro)
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            task.add_done_callback(lambda t: t.cancelled() or t.exception())
            raise

    async def stream(self, track: Track, country: str, variant: str | None = None) -> AsyncIterator[AdapterEvent]:
        """Events per adapter as they finish.

        No database connection is held while adapters are running (up to several seconds):
        a session is opened only for the few milliseconds of each read or write. Holding one
        for the whole stream let a dozen simultaneous streams use up the connection pool.
        """
        info = track_info(track)
        ctx = ResolveContext(track=info, country=country, variant=variant, http=self.http,
                             cache=self.cache, settings=self.settings)
        hidden = await self._finish(self._load_hidden(info.id))
        tasks: dict[asyncio.Task, tuple[Adapter, str]] = {}
        try:
            for adapter in self.adapters:
                key = self._cache_key(info, country, variant, adapter.name)
                cached = await self.cache.get_json(key)
                if cached is not None:
                    yield AdapterEvent(adapter.name, [l for l in cached if l["id"] not in hidden], cached=True)
                    continue
                tasks[asyncio.create_task(self._run(adapter, ctx))] = (adapter, key)
            pending = set(tasks)
            while pending:
                done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    adapter, key = tasks[task]
                    links, degraded = task.result()
                    rows = await self._finish(self._store(info.id, country, links))
                    if degraded:
                        ttl = self.settings.link_cache_ttl_degraded_s
                    elif any(l["match"] == EXACT for l in rows):
                        ttl = self.settings.link_cache_ttl_exact_s
                    else:
                        ttl = self.settings.link_cache_ttl_empty_s
                    await self.cache.set_json(key, rows, ttl)
                    yield AdapterEvent(adapter.name, rows, degraded=degraded)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()

    async def resolve_all(self, track: Track, country: str, variant: str | None = None) -> list[dict[str, Any]]:
        links: list[dict[str, Any]] = []
        async for event in self.stream(track, country, variant):
            links.extend(event.links)
        return sort_links(links)
