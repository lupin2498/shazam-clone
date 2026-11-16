"""Canned results for trying the app end-to-end without engine keys (DEMO_MODE=true).

Never enable in production: every sample "matches" one of these tracks.
"""

from __future__ import annotations

import hashlib

from .base import EngineMatch, TrackMeta

DEMO_TRACKS = [
    TrackMeta(title="Bohemian Rhapsody", artists=["Queen"], album="A Night at the Opera",
              duration_ms=354000, genres=["Rock"]),
    TrackMeta(title="Clair de Lune", artists=["Claude Debussy"], album="Suite bergamasque",
              duration_ms=300000, genres=["Classical"]),
    TrackMeta(title="Shape of You (Instrumental)", artists=["Ed Sheeran"], duration_ms=233000, genres=["Pop"]),
]


def demo_matches(audio: bytes, mode: str) -> tuple[str, list[EngineMatch]]:
    pick = hashlib.sha256(audio).digest()[0] % len(DEMO_TRACKS)
    if mode == "hum":
        ordered = DEMO_TRACKS[pick:] + DEMO_TRACKS[:pick]
        return "candidates", [
            EngineMatch(track=t, confidence=round(0.82 - i * 0.2, 2), engine="demo", via="cover")
            for i, t in enumerate(ordered)
        ]
    return "matched", [EngineMatch(track=DEMO_TRACKS[pick], confidence=0.95, engine="demo")]
