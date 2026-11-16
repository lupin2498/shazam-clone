"""Apple Music (listen) and iTunes Store (buy).

Primary source is the link AudD returns. Otherwise the public iTunes Search API
(no key, ~20 calls/min) is tried before falling back to an Apple Music search link.
"""

from __future__ import annotations

from ..base import BUY, EXACT, LISTEN, Adapter, LinkOut, ResolveContext, compact

ITUNES_SEARCH = "https://itunes.apple.com/search"


class AppleMusicAdapter(Adapter):
    name = "apple_music"
    platforms = ("apple_music", "itunes")

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        url = ctx.track.external_ids.get("apple_music_url")
        if url:
            return [LinkOut("apple_music", LISTEN, EXACT, url, ctx.track.title, ctx.track.duration_ms, 1.0)]
        resp = await ctx.http.get(
            ITUNES_SEARCH,
            params={"term": ctx.query, "media": "music", "entity": "song", "country": ctx.country, "limit": 10},
        )
        resp.raise_for_status()
        best, best_score = None, 0.0
        for it in resp.json().get("results") or []:
            score = ctx.score(it.get("trackName") or "", it.get("artistName"), it.get("trackTimeMillis"))
            if ctx.accept(score) and score > best_score:
                best, best_score = it, score
        if best is None or not best.get("trackViewUrl"):
            return self.fallback(ctx)
        url = best["trackViewUrl"]
        title, duration = best.get("trackName"), best.get("trackTimeMillis")
        links = [LinkOut("apple_music", LISTEN, EXACT, url, title, duration, best_score)]
        if (best.get("trackPrice") or 0) > 0:
            # Same page; "app=itunes" opens the store instead of the streaming app on Apple devices.
            buy_url = f"{url}{'&' if '?' in url else '?'}app=itunes"
            links.append(LinkOut("itunes", BUY, EXACT, buy_url, title, duration, best_score))
        return links

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        return compact(ctx.search_link("apple_music"))
