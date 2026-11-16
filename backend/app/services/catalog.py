"""Public, key-less catalogues (Deezer, iTunes Search) used for artwork, manual search and ISRC lookups."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import httpx

from ..cache import Cache
from ..recognition.base import TrackMeta
from ..text import score_match

log = logging.getLogger(__name__)

DEEZER_API = "https://api.deezer.com"
ITUNES_API = "https://itunes.apple.com"


def deezer_to_meta(item: dict[str, Any]) -> TrackMeta:
    album = item.get("album") or {}
    ids = {"deezer": str(item["id"])} if item.get("id") else {}
    return TrackMeta(
        title=item.get("title") or "",
        artists=[(item.get("artist") or {}).get("name", "")] if item.get("artist") else [],
        album=album.get("title"),
        duration_ms=int(item["duration"]) * 1000 if item.get("duration") else None,
        isrc=item.get("isrc"),
        artwork_url=album.get("cover_xl") or album.get("cover_big"),
        release_date=item.get("release_date"),
        external_ids=ids,
    )


def itunes_to_meta(item: dict[str, Any]) -> TrackMeta:
    art = item.get("artworkUrl100")
    ids = {"apple_music_url": item["trackViewUrl"]} if item.get("trackViewUrl") else {}
    return TrackMeta(
        title=item.get("trackName") or "",
        artists=[item["artistName"]] if item.get("artistName") else [],
        album=item.get("collectionName"),
        duration_ms=item.get("trackTimeMillis"),
        artwork_url=art.replace("100x100bb", "600x600bb") if art else None,
        release_date=(item.get("releaseDate") or "")[:10] or None,
        genres=[item["primaryGenreName"]] if item.get("primaryGenreName") else [],
        external_ids=ids,
    )


class Catalog:
    def __init__(self, http: httpx.AsyncClient, cache: Cache):
        self.http = http
        self.cache = cache

    async def deezer_by_isrc(self, isrc: str) -> dict[str, Any] | None:
        key = f"dz:isrc:{isrc}"
        cached = await self.cache.get_json(key)
        if cached is not None:
            return cached or None
        resp = await self.http.get(f"{DEEZER_API}/track/isrc:{isrc}")
        resp.raise_for_status()
        body = resp.json()
        found = body if body.get("id") and not body.get("error") else {}
        await self.cache.set_json(key, found, 30 * 86400 if found else 86400)
        return found or None

    async def deezer_search(self, query: str, limit: int = 10) -> list[dict[str, Any]]:
        resp = await self.http.get(f"{DEEZER_API}/search", params={"q": query, "limit": limit})
        resp.raise_for_status()
        return list(resp.json().get("data") or [])

    async def itunes_search(self, query: str, country: str, limit: int = 10) -> list[dict[str, Any]]:
        resp = await self.http.get(
            f"{ITUNES_API}/search",
            params={"term": query, "media": "music", "entity": "song", "country": country, "limit": limit},
        )
        resp.raise_for_status()
        return list(resp.json().get("results") or [])

    async def search(self, query: str, country: str, limit: int = 10) -> list[TrackMeta]:
        """Manual search by name when recognition fails (``GET /v1/search``)."""
        try:
            items = await self.deezer_search(query, limit)
            if items:
                return [deezer_to_meta(i) for i in items if i.get("title")]
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("deezer search failed: %s", exc)
        try:
            items = await self.itunes_search(query, country, limit)
            return [itunes_to_meta(i) for i in items if i.get("trackName")]
        except (httpx.HTTPError, ValueError) as exc:
            log.warning("itunes search failed: %s", exc)
            return []

    async def enrich(self, meta: TrackMeta, timeout_s: float) -> None:
        """Best-effort artwork (and Deezer id) for the result screen. Never raises."""
        if meta.artwork_url:
            return
        try:
            await asyncio.wait_for(self._enrich(meta), timeout_s)
        except Exception as exc:  # noqa: BLE001 - artwork is optional
            log.info("artwork lookup skipped: %s", exc)

    async def _enrich(self, meta: TrackMeta) -> None:
        item: dict[str, Any] | None = None
        if meta.isrc:
            item = await self.deezer_by_isrc(meta.isrc)
        if not item and meta.title:
            query = f'artist:"{meta.artists[0]}" track:"{meta.title}"' if meta.artists else meta.title
            for cand in await self.deezer_search(query, 5):
                found = deezer_to_meta(cand)
                if score_match(title=meta.title, artists=meta.artists, duration_ms=meta.duration_ms,
                               cand_title=found.title, cand_artist=found.artists[0] if found.artists else None,
                               cand_duration_ms=found.duration_ms) >= 0.8:
                    item = cand
                    break
        if item:
            album = item.get("album") or {}
            meta.artwork_url = album.get("cover_xl") or album.get("cover_big") or meta.artwork_url
            if item.get("id"):
                meta.external_ids.setdefault("deezer", str(item["id"]))
            if not meta.duration_ms and item.get("duration"):
                meta.duration_ms = int(item["duration"]) * 1000
