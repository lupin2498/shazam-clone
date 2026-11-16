"""Legal download/buy sources (section 7): Bandcamp, Jamendo, Internet Archive and other
Creative Commons catalogues. The app never downloads anything itself: every link
opens the source's own page.
"""

from __future__ import annotations

from ...text import is_classical
from ..base import BUY, EXACT, FREE_DOWNLOAD, LISTEN, Adapter, LinkOut, ResolveContext, compact
from ..licenses import is_open_license, license_from_url

JAMENDO_API = "https://api.jamendo.com/v3.0/tracks/"
ARCHIVE_SEARCH = "https://archive.org/advancedsearch.php"


class BandcampAdapter(Adapter):
    """No public search API: a "Tìm trên Bandcamp" link in the Buy group."""

    name = "bandcamp"
    platforms = ("bandcamp",)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        return self.fallback(ctx)

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        return compact(ctx.search_link("bandcamp", kind=BUY, query=ctx.query))


class JamendoAdapter(Adapter):
    name = "jamendo"
    platforms = ("jamendo",)

    def enabled(self, settings) -> bool:
        return bool(settings.jamendo_client_id)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        resp = await ctx.http.get(JAMENDO_API, params={
            "client_id": ctx.settings.jamendo_client_id, "format": "json", "limit": 5,
            "search": ctx.query, "include": "licenses", "audiodownload_allowed": "true",
        })
        resp.raise_for_status()
        best, best_score = None, 0.0
        for it in resp.json().get("results") or []:
            duration = int(it["duration"]) * 1000 if it.get("duration") else None
            score = ctx.score(it.get("name") or "", it.get("artist_name"), duration)
            if ctx.accept(score) and score > best_score:
                best, best_score = it, score
        if best is None:
            return []
        url = best.get("shareurl") or f"https://www.jamendo.com/track/{best['id']}"
        duration = int(best["duration"]) * 1000 if best.get("duration") else None
        lic = license_from_url(best.get("license_ccurl"))
        return [
            LinkOut("jamendo", LISTEN, EXACT, url, best.get("name"), duration, best_score, lic),
            LinkOut("jamendo", FREE_DOWNLOAD, EXACT, url, best.get("name"), duration, best_score, lic),
        ]


class InternetArchiveAdapter(Adapter):
    """Only items whose licence URL is Creative Commons or public domain."""

    name = "internet_archive"
    platforms = ("internet_archive",)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        title = ctx.track.title.replace('"', " ")
        q = (f'title:("{title}") AND mediatype:(audio) AND '
             "(licenseurl:*creativecommons* OR licenseurl:*publicdomain*)")
        resp = await ctx.http.get(ARCHIVE_SEARCH, params=[
            ("q", q), ("fl[]", "identifier"), ("fl[]", "title"), ("fl[]", "creator"),
            ("fl[]", "licenseurl"), ("rows", "5"), ("output", "json"),
        ])
        resp.raise_for_status()
        best, best_score = None, 0.0
        for doc in (resp.json().get("response") or {}).get("docs") or []:
            creator = doc.get("creator")
            creator = ", ".join(creator) if isinstance(creator, list) else creator
            score = ctx.score(str(doc.get("title") or ""), creator, None)
            if ctx.accept(score) and score > best_score and is_open_license(license_from_url(doc.get("licenseurl"))):
                best, best_score = doc, score
        if best is None:
            return []
        return [LinkOut("internet_archive", FREE_DOWNLOAD, EXACT, f"https://archive.org/details/{best['identifier']}",
                        str(best.get("title")), None, best_score, license_from_url(best.get("licenseurl")))]


class CreativeCommonsSearchAdapter(Adapter):
    """Search links on open-licence catalogues, only for no-vocals music where they are likely to help."""

    name = "cc_search"
    platforms = ("free_music_archive", "jamendo", "musopen")

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        return self.fallback(ctx)

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        t = ctx.track
        if not t.is_instrumental:
            return []
        links = compact(ctx.search_link("free_music_archive", kind=FREE_DOWNLOAD, query=ctx.query))
        if not ctx.settings.jamendo_client_id:
            links += compact(ctx.search_link("jamendo", kind=FREE_DOWNLOAD, query=ctx.query))
        if is_classical(t.title, t.genres):
            links += compact(ctx.search_link("musopen", kind=FREE_DOWNLOAD, query=t.work_title or t.title))
        return links
