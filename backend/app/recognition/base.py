from __future__ import annotations

import re
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


_SEPARATORS = (" feat. ", " ft. ", ", ", " & ", " x ", "; ")

# Acts whose own name contains one of the separators above. A free-text artist string
# ("Tyler, The Creator & Frank Ocean") cannot be split correctly without knowing them;
# engines that return a structured artist list should be read from that list instead.
_NAMES_WITH_SEPARATORS = sorted([
    "Tyler, The Creator", "Earth, Wind & Fire", "Crosby, Stills, Nash & Young", "Crosby, Stills & Nash",
    "Emerson, Lake & Palmer", "Blood, Sweat & Tears", "Peter, Paul and Mary", "Peter, Paul & Mary",
    "Simon & Garfunkel", "Hall & Oates", "Kool & The Gang", "Mumford & Sons", "Belle & Sebastian",
    "Florence & The Machine", "Bob Marley & The Wailers", "Chloe x Halle", "Years & Years", "Above & Beyond",
    "Brooks & Dunn", "She & Him", "Angus & Julia Stone", "Nick Cave & The Bad Seeds", "Marina & The Diamonds",
    "Echo & The Bunnymen", "Hootie & The Blowfish", "Tom Petty & The Heartbreakers", "Sly & The Family Stone",
    "KC & The Sunshine Band", "Huey Lewis & The News", "Gladys Knight & The Pips", "Derek & The Dominos",
    "Wisin & Yandel", "Zion & Lennox", "Chase & Status", "Sam & Dave", "Ike & Tina Turner", "Seals & Crofts",
    "Captain & Tennille", "Prince & The Revolution", "Katrina & The Waves", "Martha & The Vandellas",
    "Smokey Robinson & The Miracles", "Booker T. & The M.G.'s", "Dan + Shay",
], key=len, reverse=True)
_KEEP_WHOLE = re.compile(
    r"(?<![\w])(?:" + "|".join(re.escape(name) for name in _NAMES_WITH_SEPARATORS) + r")(?![\w])", re.IGNORECASE
)


def split_artists(raw: str | None) -> list[str]:
    """Split a free-text artist credit into names, keeping known names that contain a separator."""
    if not raw or not isinstance(raw, str):
        return []
    kept: list[str] = []

    def protect(match: re.Match[str]) -> str:
        kept.append(match.group(0))
        return f"\x00{len(kept) - 1}\x00"

    parts = [_KEEP_WHOLE.sub(protect, raw)]
    for sep in _SEPARATORS:
        parts = [p for chunk in parts for p in chunk.split(sep)]
    names = []
    for part in parts:
        name = re.sub(r"\x00(\d+)\x00", lambda m: kept[int(m.group(1))], part).strip()
        if name:
            names.append(name)
    return names
