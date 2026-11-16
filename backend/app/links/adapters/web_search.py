"""Whitelisted web search (F9). Provider: Brave Search API; disabled without a key.

Only results on approved domains are kept (section 7: never link to unlicensed
sharing sites), and every result must pass the same match threshold.
"""

from __future__ import annotations

from urllib.parse import urlparse

from ..base import BUY, EXACT, FREE_DOWNLOAD, Adapter, LinkOut, ResolveContext

API = "https://api.search.brave.com/res/v1/web/search"

DOMAIN_PLATFORM = {
    "bandcamp.com": ("bandcamp", BUY),
    "freemusicarchive.org": ("free_music_archive", FREE_DOWNLOAD),
    "jamendo.com": ("jamendo", FREE_DOWNLOAD),
    "archive.org": ("internet_archive", FREE_DOWNLOAD),
    "musopen.org": ("musopen", FREE_DOWNLOAD),
}


def allowed_domain(url: str, whitelist: set[str]) -> str | None:
    host = (urlparse(url).hostname or "").lower()
    for domain in whitelist:
        if host == domain or host.endswith("." + domain):
            return domain
    return None


class WebSearchAdapter(Adapter):
    name = "web_search"
    platforms = ("bandcamp", "free_music_archive", "jamendo", "internet_archive", "musopen", "web")

    def enabled(self, settings) -> bool:
        return bool(settings.brave_search_api_key)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        resp = await ctx.http.get(
            API,
            params={"q": f'"{ctx.track.title}" {ctx.track.artist}', "count": 10},
            headers={"X-Subscription-Token": ctx.settings.brave_search_api_key, "Accept": "application/json"},
        )
        resp.raise_for_status()
        whitelist = ctx.settings.web_whitelist
        links: list[LinkOut] = []
        for r in (resp.json().get("web") or {}).get("results") or []:
            url = r.get("url") or ""
            domain = allowed_domain(url, whitelist)
            if not domain:
                continue
            score = ctx.score(r.get("title") or "", None, None)
            if not ctx.accept(score):
                continue
            platform, kind = DOMAIN_PLATFORM.get(domain, ("web", FREE_DOWNLOAD))
            links.append(LinkOut(platform, kind, EXACT, url, r.get("title"), None, score))
        return links[:5]
