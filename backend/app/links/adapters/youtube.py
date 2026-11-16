"""YouTube / YouTube Music.

Primary source is the video id returned by the recognition engine. The Data API
``search.list`` costs 100 units, so a project gets ~100 searches per day by
default: the adapter counts them and falls back to a search link when the
budget is spent.
"""

from __future__ import annotations

import html
import re
from datetime import datetime, timedelta, timezone

from ..base import EXACT, LISTEN, Adapter, LinkOut, QuotaExhausted, ResolveContext, compact, safe_platform_id

API = "https://www.googleapis.com/youtube/v3"
_ISO_DURATION = re.compile(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?")


def iso_duration_ms(value: str | None) -> int | None:
    m = _ISO_DURATION.fullmatch(value or "")
    if not m or not any(m.groups()):
        return None
    d, h, mi, s = (int(x or 0) for x in m.groups())
    return ((d * 24 + h) * 3600 + mi * 60 + s) * 1000


def _quota_key() -> str:
    # The YouTube quota resets at midnight Pacific time.
    day = (datetime.now(timezone.utc) - timedelta(hours=8)).strftime("%Y%m%d")
    return f"ytq:{day}"


def watch_url(video_id: str, music: bool = False) -> str:
    host = "music.youtube.com" if music else "www.youtube.com"
    return f"https://{host}/watch?v={video_id}"


class YouTubeAdapter(Adapter):
    name = "youtube"
    platforms = ("youtube",)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        vid = safe_platform_id(ctx.track.external_ids.get("youtube"))
        if vid:
            return [LinkOut("youtube", LISTEN, EXACT, watch_url(vid), ctx.track.title, ctx.track.duration_ms, 1.0)]
        found = await self._search(ctx) if ctx.settings.youtube_api_key else None
        if found:
            return [found] + self._variant_links(ctx)
        return self.fallback(ctx)

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        return compact(ctx.search_link("youtube")) + self._variant_links(ctx)

    def _variant_links(self, ctx: ResolveContext) -> list[LinkOut]:
        # "có thể là bản beat": add keyword searches for the beat/karaoke/instrumental version.
        if ctx.variant != "beat":
            return []
        return compact(ctx.search_link("youtube", query=f"{ctx.query} beat karaoke instrumental"))

    async def _search(self, ctx: ResolveContext) -> LinkOut | None:
        used = await ctx.cache.incr(_quota_key(), 2 * 86400)
        if used > ctx.settings.youtube_search_daily_limit:
            raise QuotaExhausted("youtube search.list budget spent")
        params = {
            "part": "snippet", "type": "video", "maxResults": 5, "q": ctx.free_text_query(),
            "regionCode": ctx.country, "videoCategoryId": "10", "key": ctx.settings.youtube_api_key,
        }
        resp = await ctx.http.get(f"{API}/search", params=params)
        if resp.status_code == 403 and "quota" in resp.text.lower():
            await ctx.cache.set(_quota_key(), str(ctx.settings.youtube_search_daily_limit), 2 * 86400)
            raise QuotaExhausted("youtube quotaExceeded")
        resp.raise_for_status()
        items = [i for i in resp.json().get("items") or [] if safe_platform_id((i.get("id") or {}).get("videoId"))]
        if not items:
            return None
        ids = [i["id"]["videoId"] for i in items]
        durations: dict[str, int | None] = {}
        details = await ctx.http.get(
            f"{API}/videos", params={"part": "contentDetails", "id": ",".join(ids), "key": ctx.settings.youtube_api_key}
        )
        if details.status_code == 200:
            for v in details.json().get("items") or []:
                durations[v["id"]] = iso_duration_ms((v.get("contentDetails") or {}).get("duration"))
        best: LinkOut | None = None
        for item in items:
            vid = item["id"]["videoId"]
            snippet = item.get("snippet") or {}
            title = html.unescape(snippet.get("title") or "")
            score = ctx.score(title, html.unescape(snippet.get("channelTitle") or ""), durations.get(vid))
            if ctx.accept(score) and (best is None or score > best.score):
                best = LinkOut("youtube", LISTEN, EXACT, watch_url(vid), title, durations.get(vid), score)
        return best


class YouTubeMusicAdapter(Adapter):
    """No API calls: reuses the engine's video id, otherwise a search link. Offline needs YouTube Premium."""

    name = "youtube_music"
    platforms = ("youtube_music",)

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        vid = safe_platform_id(ctx.track.external_ids.get("youtube"))
        if vid:
            listen = LinkOut("youtube_music", LISTEN, EXACT, watch_url(vid, music=True), ctx.track.title,
                             ctx.track.duration_ms, 1.0)
            return compact(listen, ctx.offline_link("youtube_music", listen))
        return self.fallback(ctx)

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        listen = ctx.search_link("youtube_music")
        return compact(listen, ctx.offline_link("youtube_music", listen))
