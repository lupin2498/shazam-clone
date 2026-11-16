"""Spotify: engine id first, then Web API search (ISRC, then name), then a search link.

Development-mode apps get at most 10 results per search (2026 rules), which is
all the adapter asks for.
"""

from __future__ import annotations

from ..base import EXACT, LISTEN, Adapter, AdapterError, LinkOut, ResolveContext, compact, safe_platform_id

TOKEN_URL = "https://accounts.spotify.com/api/token"
API = "https://api.spotify.com/v1"


def track_url(track_id: str) -> str:
    return f"https://open.spotify.com/track/{track_id}"


class SpotifyAdapter(Adapter):
    name = "spotify"
    platforms = ("spotify",)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        sid = safe_platform_id(ctx.track.external_ids.get("spotify"))
        listen: LinkOut | None = None
        if sid:
            listen = LinkOut("spotify", LISTEN, EXACT, track_url(sid), ctx.track.title, ctx.track.duration_ms, 1.0)
        elif ctx.settings.spotify_client_id and ctx.settings.spotify_client_secret:
            listen = await self._search(ctx)
        if listen is None:
            return self.fallback(ctx)
        return compact(listen, ctx.offline_link("spotify", listen))

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        listen = ctx.search_link("spotify")
        return compact(listen, ctx.offline_link("spotify", listen))

    async def _token(self, ctx: ResolveContext) -> str:
        cached = await ctx.cache.get("spotify:token")
        if cached:
            return cached
        resp = await ctx.http.post(
            TOKEN_URL,
            data={"grant_type": "client_credentials"},
            auth=(ctx.settings.spotify_client_id, ctx.settings.spotify_client_secret),
        )
        resp.raise_for_status()
        body = resp.json()
        token = body["access_token"]
        await ctx.cache.set("spotify:token", token, max(int(body.get("expires_in", 3600)) - 60, 60))
        return token

    async def _query(self, ctx: ResolveContext, q: str, limit: int) -> list[dict]:
        resp = await ctx.http.get(
            f"{API}/search",
            params={"q": q, "type": "track", "limit": limit, "market": ctx.country},
            headers={"Authorization": f"Bearer {await self._token(ctx)}"},
        )
        if resp.status_code == 401:
            await ctx.cache.delete("spotify:token")
        if resp.status_code == 429:
            raise AdapterError("spotify rate limited")
        resp.raise_for_status()
        return list((resp.json().get("tracks") or {}).get("items") or [])

    async def _search(self, ctx: ResolveContext) -> LinkOut | None:
        t = ctx.track
        if t.isrc:
            items = await self._query(ctx, f"isrc:{t.isrc}", 1)
            if items:
                it = items[0]
                return LinkOut("spotify", LISTEN, EXACT, it["external_urls"]["spotify"], it.get("name"),
                               it.get("duration_ms"), 1.0)
        q = f'track:"{t.title}" artist:"{t.artist}"' if t.artist else f'track:"{t.title}"'
        best: LinkOut | None = None
        for it in await self._query(ctx, q, 10):
            artist = ", ".join(a.get("name", "") for a in it.get("artists") or [])
            score = ctx.score(it.get("name") or "", artist, it.get("duration_ms"))
            if ctx.accept(score) and (best is None or score > best.score):
                best = LinkOut("spotify", LISTEN, EXACT, it["external_urls"]["spotify"], it.get("name"),
                               it.get("duration_ms"), score)
        return best
