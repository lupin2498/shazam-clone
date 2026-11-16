from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class TrackMeta:
    title: str
    artists: list[str]
    album: str | None = None
    duration_ms: int | None = None
    isrc: str | None = None
    artwork_url: str | None = None
    release_date: str | None = None
    genres: list[str] = field(default_factory=list)
    # spotify, youtube, deezer, apple_music_url, acrid, song_link...
    external_ids: dict[str, str] = field(default_factory=dict)


@dataclass
class EngineMatch:
    track: TrackMeta
    confidence: float  # 0..1
    engine: str
    via: str = "fingerprint"  # fingerprint | cover


class EngineError(Exception):
    """The engine could not answer (network, auth, malformed response)."""


class EngineQuotaError(EngineError):
    """The engine refused because a plan or rate limit was hit."""


def split_artists(raw: str | None) -> list[str]:
    if not raw:
        return []
    parts = [raw]
    for sep in (" feat. ", " ft. ", ", ", " & ", " x ", "; "):
        parts = [p for chunk in parts for p in chunk.split(sep)]
    return [p.strip() for p in parts if p.strip()]
