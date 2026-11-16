"""Building blocks shared by every link adapter (section 6)."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

import httpx

from ..cache import Cache
from ..config import Settings
from ..platforms import PLATFORMS, search_url
from ..text import has_instrumental_marker, is_classical, is_instrumental_version, score_match

LISTEN, BUY, FREE_DOWNLOAD, OFFLINE = "listen", "buy", "free_download", "offline_in_app"
EXACT, SEARCH = "exact", "search"


@dataclass
class LinkOut:
    platform: str
    kind: str
    match: str
    url: str
    title: str | None = None
    duration_ms: int | None = None
    score: float = 0.0
    license: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class TrackInfo:
    id: str
    title: str
    artists: list[str]
    duration_ms: int | None = None
    isrc: str | None = None
    is_instrumental: bool = False
    work_title: str | None = None
    genres: list[str] = field(default_factory=list)
    external_ids: dict[str, str] = field(default_factory=dict)

    @property
    def artist(self) -> str:
        return self.artists[0] if self.artists else ""

    @property
    def cache_key(self) -> str:
        return self.isrc or self.id


@dataclass
class ResolveContext:
    track: TrackInfo
    country: str
    variant: str | None
    http: httpx.AsyncClient
    cache: Cache
    settings: Settings

    @property
    def query(self) -> str:
        """"tên bài + nghệ sĩ" used for name-based search."""
        return f"{self.track.title} {self.track.artist}".strip()

    @property
    def wants_instrumental_keyword(self) -> bool:
        """Add "instrumental" to free-text queries for no-vocals tracks whose title lacks a marker."""
        t = self.track
        return t.is_instrumental and not has_instrumental_marker(t.title) and not is_classical(t.title, t.genres)

    @property
    def require_instrumental(self) -> bool:
        """Reject vocal versions with the same name (section 6, last paragraph)."""
        return self.track.is_instrumental and is_instrumental_version(self.track.title)

    def free_text_query(self) -> str:
        q = self.query
        return f"{q} instrumental" if self.wants_instrumental_keyword else q

    def score(self, cand_title: str, cand_artist: str | None, cand_duration_ms: int | None,
              tolerance_s: float | None = None) -> float:
        return score_match(
            title=self.track.title,
            artists=self.track.artists,
            duration_ms=self.track.duration_ms,
            cand_title=cand_title,
            cand_artist=cand_artist,
            cand_duration_ms=cand_duration_ms,
            tolerance_s=self.settings.duration_tolerance_s if tolerance_s is None else tolerance_s,
            require_instrumental=self.require_instrumental,
        )

    def accept(self, score: float) -> bool:
        return score >= self.settings.match_score_threshold

    def search_link(self, platform: str, *, kind: str = LISTEN, query: str | None = None) -> LinkOut | None:
        q = query or self.free_text_query()
        url = search_url(platform, q, self.country, self.settings.search_url_overrides)
        if not url:
            return None
        return LinkOut(platform=platform, kind=kind, match=SEARCH, url=url, title=q)

    def offline_link(self, platform: str, listen: LinkOut | None) -> LinkOut | None:
        """"Mở app để tải offline" entry pointing at the same page as the listen link."""
        if listen is None or not PLATFORMS[platform].offline_in_app:
            return None
        return LinkOut(platform=platform, kind=OFFLINE, match=listen.match, url=listen.url,
                       title=listen.title, duration_ms=listen.duration_ms, score=listen.score)


class AdapterError(Exception):
    pass


class QuotaExhausted(AdapterError):
    """The platform's own API quota is used up; fall back to a search link."""


class Adapter:
    """One platform (or aggregator). ``resolve`` may call APIs; ``fallback`` must not."""

    name: str = ""
    # Platform ids this adapter can emit links for (published in /v1/config).
    platforms: tuple[str, ...] = ()
    timeout_s: float | None = None

    def enabled(self, settings: Settings) -> bool:
        return True

    async def resolve(self, ctx: ResolveContext) -> list[LinkOut]:
        raise NotImplementedError

    def fallback(self, ctx: ResolveContext) -> list[LinkOut]:
        return []


def compact(*links: LinkOut | None) -> list[LinkOut]:
    return [link for link in links if link is not None]
