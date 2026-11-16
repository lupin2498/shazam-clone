"""Zing MP3 and NhacCuaTui have no public API: deep search links that open the results page.

Both apps can download for offline listening, so each also gets a "Mở app để tải offline" entry.
"""

from __future__ import annotations

from ..base import Adapter, LinkOut, ResolveContext, compact


class _DeepSearchAdapter(Adapter):
    platform = ""

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        return self.fallback(ctx)

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        # Vietnamese catalogues index titles with their own spelling; search by "tên bài + nghệ sĩ".
        listen = ctx.search_link(self.platform, query=ctx.query)
        links = compact(listen, ctx.offline_link(self.platform, listen))
        if ctx.variant == "beat":
            links += compact(ctx.search_link(self.platform, query=f"{ctx.track.title} beat"))
        return links


class ZingMp3Adapter(_DeepSearchAdapter):
    name = "zing_mp3"
    platform = "zing_mp3"
    platforms = ("zing_mp3",)


class NctAdapter(_DeepSearchAdapter):
    name = "nct"
    platform = "nct"
    platforms = ("nct",)
