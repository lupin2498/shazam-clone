"""Odesli / song.link: one call returns links on 20+ services.

Supplementary only (section 6): no key is issued any more, 10 requests/min
anonymous, and the v1-alpha.1 API has an announced shutdown. Platforms already
covered by a primary adapter are dropped, so nothing depends on it.
"""

from __future__ import annotations

from datetime import datetime, timezone

from ...services.catalog import Catalog
from ..base import BUY, EXACT, LISTEN, Adapter, LinkOut, ResolveContext

API = "https://api.song.link/v1-alpha.1/links"

# Odesli platform key → (our platform id, kind). Everything else is handled by primary adapters.
KEEP = {
    "tidal": ("tidal", LISTEN),
    "amazonMusic": ("amazon_music", LISTEN),
    "amazonStore": ("amazon_store", BUY),
    "pandora": ("pandora", LISTEN),
    "napster": ("napster", LISTEN),
    "yandex": ("yandex", LISTEN),
    "audiomack": ("audiomack", LISTEN),
    "anghami": ("anghami", LISTEN),
    "boomplay": ("boomplay", LISTEN),
    "audius": ("audius", LISTEN),
}


class OdesliAdapter(Adapter):
    name = "odesli"
    platforms = tuple(p for p, _ in KEEP.values())
    timeout_s = 4.0

    def enabled(self, settings) -> bool:
        return settings.odesli_enabled

    async def _seed(self, ctx: ResolveContext) -> str | None:
        ids = ctx.track.external_ids
        if ids.get("spotify"):
            return f"https://open.spotify.com/track/{ids['spotify']}"
        if ids.get("deezer"):
            return f"https://www.deezer.com/track/{ids['deezer']}"
        if ids.get("apple_music_url"):
            return ids["apple_music_url"]
        if ids.get("youtube"):
            return f"https://www.youtube.com/watch?v={ids['youtube']}"
        if ctx.track.isrc:
            item = await Catalog(ctx.http, ctx.cache).deezer_by_isrc(ctx.track.isrc)
            if item and item.get("id"):
                return f"https://www.deezer.com/track/{item['id']}"
        return None

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        seed = await self._seed(ctx)
        if not seed:
            return []
        minute = datetime.now(timezone.utc).strftime("%Y%m%d%H%M")
        if await ctx.cache.incr(f"odesli:{minute}", 120) > ctx.settings.odesli_per_minute:
            return []
        resp = await ctx.http.get(API, params={"url": seed, "userCountry": ctx.country})
        if resp.status_code in (400, 404):
            return []
        resp.raise_for_status()
        links = []
        for key, item in (resp.json().get("linksByPlatform") or {}).items():
            if key in KEEP and item.get("url"):
                platform, kind = KEEP[key]
                links.append(LinkOut(platform, kind, EXACT, item["url"], ctx.track.title, None, 0.9))
        return links
