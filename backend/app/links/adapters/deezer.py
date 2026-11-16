"""Deezer public API: engine id, then ISRC lookup, then name search. No key needed."""

from __future__ import annotations

from ...services.catalog import Catalog
from ..base import EXACT, LISTEN, Adapter, LinkOut, ResolveContext, compact


def track_url(track_id: str) -> str:
    return f"https://www.deezer.com/track/{track_id}"


class DeezerAdapter(Adapter):
    name = "deezer"
    platforms = ("deezer",)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        t = ctx.track
        if t.external_ids.get("deezer"):
            return [LinkOut("deezer", LISTEN, EXACT, track_url(t.external_ids["deezer"]), t.title, t.duration_ms, 1.0)]
        catalog = Catalog(ctx.http, ctx.cache)
        if t.isrc:
            item = await catalog.deezer_by_isrc(t.isrc)
            if item:
                return [LinkOut("deezer", LISTEN, EXACT, item.get("link") or track_url(str(item["id"])),
                                item.get("title"), (item.get("duration") or 0) * 1000 or None, 1.0)]
        query = f'artist:"{t.artist}" track:"{t.title}"' if t.artist else t.title
        best, best_score = None, 0.0
        for it in await catalog.deezer_search(query, 10):
            duration = (it.get("duration") or 0) * 1000 or None
            score = ctx.score(it.get("title") or "", (it.get("artist") or {}).get("name"), duration)
            if ctx.accept(score) and score > best_score:
                best, best_score = it, score
        if best is None:
            return self.fallback(ctx)
        return [LinkOut("deezer", LISTEN, EXACT, best.get("link") or track_url(str(best["id"])), best.get("title"),
                        (best.get("duration") or 0) * 1000 or None, best_score)]

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        return compact(ctx.search_link("deezer"))
