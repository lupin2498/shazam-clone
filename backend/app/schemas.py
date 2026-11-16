from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from .models import Track


class TrackOut(BaseModel):
    id: str
    isrc: str | None = None
    title: str
    artists: list[str]
    album: str | None = None
    duration_ms: int | None = None
    artwork_url: str | None = None
    is_instrumental: bool = False
    work_title: str | None = None
    genres: list[str] = []
    release_date: str | None = None

    @classmethod
    def of(cls, t: Track) -> "TrackOut":
        return cls(
            id=t.id, isrc=t.isrc, title=t.title, artists=list(t.artists or []), album=t.album,
            duration_ms=t.duration_ms, artwork_url=t.artwork_url, is_instrumental=t.is_instrumental,
            work_title=t.work_title, genres=list(t.genres or []), release_date=t.release_date,
        )


class CandidateOut(BaseModel):
    track: TrackOut
    confidence: float
    rank: int
    # maybe_beat | cover | melody
    flags: list[str] = []


class RecognitionOut(BaseModel):
    id: str
    status: Literal["matched", "candidates", "no_match"]
    engine: str | None = None
    stage: Literal["early", "full"]
    # False only for an early probe without a match: keep listening and send the 12 s sample.
    final: bool = True
    candidates: list[CandidateOut] = []
    latency_ms: int
    quota_remaining: int


class SearchOut(BaseModel):
    results: list[TrackOut]


class LinkOut(BaseModel):
    id: str
    platform: str
    kind: str
    match: str
    url: str
    title: str | None = None
    duration_ms: int | None = None
    score: float = 0.0
    license: str | None = None


class LinksOut(BaseModel):
    track: TrackOut
    links: list[LinkOut]


LinkReportReason = Literal["wrong_song", "broken", "violation", "other"]


class LinkReportIn(BaseModel):
    reason: LinkReportReason
    note: str | None = Field(default=None, max_length=500)


class LinkReportOut(BaseModel):
    hidden: bool


class RecognitionReportIn(BaseModel):
    reason: Literal["wrong_song", "partly_wrong", "other"] = "wrong_song"
    note: str | None = Field(default=None, max_length=500)


class ErrorOut(BaseModel):
    error: str
    message: str
