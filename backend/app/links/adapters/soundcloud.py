"""SoundCloud official API (Client Credentials). Tokens are cached: only 50 per 12 h per app."""

from __future__ import annotations

from ..base import BUY, EXACT, FREE_DOWNLOAD, LISTEN, Adapter, LinkOut, ResolveContext, compact
from ..licenses import soundcloud_license

TOKEN_URL = "https://secure.soundcloud.com/oauth/token"
API = "https://api.soundcloud.com"


class SoundCloudAdapter(Adapter):
    name = "soundcloud"
    platforms = ("soundcloud",)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        if not (ctx.settings.soundcloud_client_id and ctx.settings.soundcloud_client_secret):
            return self.fallback(ctx)
        resp = await ctx.http.get(
            f"{API}/tracks",
            params={"q": ctx.free_text_query(), "limit": 10, "access": "playable"},
            headers={"Authorization": f"OAuth {await self._token(ctx)}"},
        )
        if resp.status_code == 401:
            await ctx.cache.delete("soundcloud:token")
        resp.raise_for_status()
        body = resp.json()
        items = body.get("collection", []) if isinstance(body, dict) else body
        best = None
        best_score = 0.0
        for it in items or []:
            score = ctx.score(it.get("title") or "", (it.get("user") or {}).get("username"), it.get("duration"))
            if ctx.accept(score) and score > best_score:
                best, best_score = it, score
        if best is None:
            return self.fallback(ctx)
        url = best["permalink_url"]
        title, duration = best.get("title"), best.get("duration")
        links = [LinkOut("soundcloud", LISTEN, EXACT, url, title, duration, best_score)]
        if best.get("downloadable"):
            # The uploader enabled downloads: open the track page, SoundCloud serves the file.
            links.append(LinkOut("soundcloud", FREE_DOWNLOAD, EXACT, url, title, duration, best_score,
                                 soundcloud_license(best.get("license"))))
        if best.get("purchase_url"):
            links.append(LinkOut("soundcloud", BUY, EXACT, best["purchase_url"], title, duration, best_score))
        return links

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        return compact(ctx.search_link("soundcloud"))

    async def _token(self, ctx: ResolveContext) -> str:
        cached = await ctx.cache.get("soundcloud:token")
        if cached:
            return cached
        resp = await ctx.http.post(
            TOKEN_URL,
            data={"grant_type": "client_credentials"},
            auth=(ctx.settings.soundcloud_client_id, ctx.settings.soundcloud_client_secret),
            headers={"accept": "application/json; charset=utf-8"},
        )
        resp.raise_for_status()
        body = resp.json()
        token = body["access_token"]
        await ctx.cache.set("soundcloud:token", token, max(int(body.get("expires_in", 3600)) - 120, 60))
        return token
